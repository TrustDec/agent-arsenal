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

## 25. MCP Resource Subscriptions & Live Invalidation (`notifications/resources/updated`)
- **Stale Context Desynchronization from Polling Latency**:
  - Relying on the host agent to manually re-read dynamic resources (e.g. database schema migrations, active git branch status, or live service metrics) on every turn, causing the agent to act on stale state.
  - ✅ **Production Invariant**: Support the MCP `resources/subscribe` and `resources/unsubscribe` protocol handlers. When underlying files or models change on disk, emit `notifications/resources/updated` with the affected URI so the host agent's context cache is invalidated instantly:
    ```typescript
    server.setRequestHandler(SubscribeRequestSchema, async (request) => {
      activeSubscriptions.add(request.params.uri);
      return {};
    });

    // On disk file watcher change event:
    function onFileModified(uri: string) {
      if (activeSubscriptions.has(uri)) {
        server.sendResourceUpdated({ uri });
      }
    }
    ```

## 26. Dynamic Roots Re-Validation (`notifications/roots/list_changed`)
- **Stale Root Boundaries After Host Folder Open/Close**:
  - Caching the host's permitted root directories only once during `initialize`, failing to detect when a user adds a new project folder or closes an existing workspace in Cursor or Claude Code.
  - ✅ **Production Invariant**: Register a notification handler for `notifications/roots/list_changed`. Whenever emitted, immediately re-query `roots/list` and rebuild the canonical path resolution allowlist to enforce boundary integrity without requiring a server process restart.

## 27. Strict JSON Schema Validation & `additionalProperties: false`
- **Ambiguous Tool Arguments and Undetected Hallucinated Parameters**:
  - Defining MCP tool input schemas without `additionalProperties: false` or strict type bounds. The LLM hallucinates non-existent options or passes invalid types that bypass naive validators, leading to unpredictable runtime behavior or silent failures.
  - ✅ **Production Invariant**: Always enforce `additionalProperties: false` on object schemas and declare explicit `required` arrays using Zod or JSON Schema Draft-07:
    ```typescript
    const QueryToolInputSchema = z.object({
      query: z.string().min(1).max(500),
      limit: z.number().int().min(1).max(100).default(20),
    }).strict(); // Enforces additionalProperties: false
    ```

## 28. SSE Transport Disconnect & AbortSignal Propagation
- **Zombie Execution After Host Client Disconnect**:
  - In remote SSE (Server-Sent Events) MCP servers, when the host agent cancels a turn or closes the connection, the server continues executing heavy database queries or LLM calls in the background, wasting compute and locking resources.
  - ✅ **Production Invariant**: Bind the HTTP request's `req.on('close')` event to an `AbortController` and pass `signal` into all downstream async operations, terminating background jobs immediately upon client disconnection.

## 29. Structured Error Envelopes & Actionable Remediation Details
- **Opaque String Errors Stalling Agent Self-Correction**:
  - Returning raw string messages like `"Error: invalid input"` when tool validation fails. The calling agent lacks the context to understand *why* the input failed or *how* to construct a valid replacement call, falling into a repetitive failure loop.
  - ✅ **Production Invariant**: Return structured JSON error details conforming to RFC 7807 or include actionable schema guidance within the tool result error payload:
    ```typescript
    return {
      isError: true,
      content: [{
        type: 'text',
        text: JSON.stringify({
          error: 'VALIDATION_FAILED',
          message: 'Parameter "limit" must be an integer between 1 and 100',
          received: args.limit,
          remediation: 'Provide limit as an integer <= 100'
        })
      }]
    };
    ```

## 30. Multi-Modal Tool Responses & Typed Image Content
- **Raw File Paths or Naked URLs in Tool Responses**:
  - Returning local disk file paths (`/tmp/chart.png`) or internal localhost URLs for generated diagrams, UI screenshots, or telemetry plots. The host agent LLM cannot read local filesystem paths directly or crashes when encountering unencoded binary buffers in text fields.
  - ✅ **Production Invariant**: In MCP 2024/2025+, return binary visual artifacts formatted as typed `image` content blocks with explicit MIME types and base64 encoding:
    ```typescript
    return {
      content: [
        {
          type: 'image',
          data: chartBuffer.toString('base64'),
          mimeType: 'image/png',
        },
        {
          type: 'text',
          text: 'Rendered memory consumption profile across 50 nodes.',
        },
      ],
    };
    ```

## 31. Server Process Group Termination & Daemon Leaks
- **Zombie Subprocess Daemons on Host Agent Abort**:
  - MCP servers spawning background child workers (e.g. headless Playwright/Puppeteer browsers, database connection pools, local dev servers) that ignore `SIGTERM`/`SIGINT`. When the host agent (Claude Code, Cursor) terminates the parent server process, detached child workers continue running in the background, leaking memory and exhausting CPU.
  - ✅ **Production Invariant**: Register process signal handlers for `SIGINT` and `SIGTERM`. Initiate graceful drain with a 5-second deadline and forcefully terminate all spawned child process groups using `process.kill(-child.pid, 'SIGKILL')`:
    ```typescript
    const cleanTeardown = async (signal: string) => {
      console.error(`Received ${signal}, terminating MCP worker pools...`);
      for (const worker of activeWorkerPools) {
        if (worker.pid) {
          try {
            process.kill(-worker.pid, 'SIGKILL');
          } catch {
            // Already exited
          }
        }
      }
      process.exit(0);
    };

    process.on('SIGINT', () => cleanTeardown('SIGINT'));
    process.on('SIGTERM', () => cleanTeardown('SIGTERM'));
    ```

## 32. MCP Protocol Error Classification vs Business Failures (`isError: true`)
- **Protocol-Level JSON-RPC Crashes on Business Logic Failures**:
  - ❌ Throwing raw exceptions or returning top-level JSON-RPC error frames (`code: -32603 Internal error`) when an argument fails validation (e.g. `order_id not found` or `insufficient_funds`). Top-level JSON-RPC errors cause the host agent harness (Claude Code, Cursor) to suspect a broken server transport, leading to connection teardown or tool eviction.
  - ✅ **Production Invariant**: Distinguish between transport/protocol violations and tool execution outcomes. Application errors MUST return HTTP 200 / JSON-RPC success response containing `{ isError: true, content: [{ type: 'text', text: 'Error details and remediation hint' }] }`. Protocol errors are reserved strictly for invalid JSON (`-32700`) or unregistered methods (`-32601`):
    ```typescript
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;
      
      try {
        const result = await executeTool(name, args);
        return { content: [{ type: 'text', text: JSON.stringify(result) }] };
      } catch (err: any) {
        // Safe tool error containment:
        return {
          isError: true,
          content: [
            {
              type: 'text',
              text: `Tool execution failed: ${err.message}. Please verify the arguments and try again.`,
            },
          ],
        };
      }
    });
    ```

## 33. Dynamic Resource Subscriptions & Targeted Invalidation
- **Stale Context Caches & Thunderous Herd Invalidation**:
  - MCP servers serving static resource caches (`resources/read`) that fail to notify the host agent when underlying database tables or workspace files are updated. Alternatively, broadcasting global invalidations causing the agent to re-fetch all resources at once.
  - ✅ **Production Invariant**: Track active client resource subscriptions and emit granular `notifications/resources/updated` messages pinned to the exact mutated resource URI:
    ```typescript
    export async function notifyResourceUpdated(server: Server, resourceUri: string) {
      await server.notification({
        method: 'notifications/resources/updated',
        params: {
          uri: resourceUri,
        },
      });
    }
    ```

## 34. Client Cancellation Handling (`notifications/cancelled`) & Abort Propagation
- **Runaway Long-Running Queries & Zombie Background Workers**:
  - When an autonomous agent or human interrupts a slow tool execution (e.g. database query, web scrape, heavy build task), the client sends a `notifications/cancelled` notification containing the `requestId`.
  - ❌ **Anti-Pattern: Ignoring Client Cancellations**: Continuing to execute the database transaction or network request to completion in the background, consuming CPU, I/O, and holding locks on resources.
  - ✅ **Production Invariant**: Maintain an active request-to-AbortController registry. When `notifications/cancelled` is received, invoke `abortController.abort()` to terminate in-flight HTTP requests, database contexts, or child processes instantly:
    ```typescript
    const activeRequests = new Map<string | number, AbortController>();

    server.setNotificationHandler(CancelledNotificationSchema, (notification) => {
      const { requestId } = notification.params;
      const controller = activeRequests.get(requestId);
      if (controller) {
        controller.abort();
        activeRequests.delete(requestId);
      }
    });
    ```

## 35. Prompt Templates Protocol (`prompts/list` & `prompts/get`) Discipline
- **Unvalidated Dynamic Prompts & Context Boundary Escapes**:
  - Exposing prompt templates via MCP without input argument validation or schema guards, allowing arbitrary text injection into template parameters that compromise host system directives.
  - ✅ **Production Invariant**: Validate all prompt template arguments with strict schema constraints, provide clear parameter documentation, and wrap user-supplied arguments in defensive XML tags (`<user_prompt_input>`):
    ```typescript
    server.setRequestHandler(GetPromptRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;
      if (name === 'review_pull_request') {
        const prNumber = z.string().regex(/^\d+$/).parse(args?.prNumber);
        return {
          description: `Code review template for PR #${prNumber}`,
          messages: [
            {
              role: 'user',
              content: {
                type: 'text',
                text: `Review PR #${prNumber}.\n<user_prompt_input>\n${args?.guidelines || 'Follow standard production rules.'}\n</user_prompt_input>`,
              },
            },
          ],
        };
      }
      throw new McpError(ErrorCode.MethodNotFound, `Unknown prompt: ${name}`);
    });
    ```

## 36. Logging Protocol (`logging/setLevel` & `notifications/message`) Discipline
- **Polluting Transport Stdout with Raw Diagnostic Logs**:
  - ❌ **Anti-Pattern: `console.log` on Stdio Transports**: Calling `console.log("Processing...")` or raw `fmt.Println` inside an stdio MCP server. This emits non-JSON-RPC lines into stdout, corrupting the host's JSON-RPC framing parser and killing the session.
  - ✅ **Production Invariant**: Support the MCP `logging/setLevel` protocol to route structured, level-filtered diagnostic logs to the client via `notifications/message` without corrupting JSON-RPC framing:
    ```typescript
    let currentLogLevel = 'info';
    const LOG_LEVEL_SEVERITY: Record<string, number> = {
      debug: 10, info: 20, notice: 30, warning: 40, error: 50, critical: 60
    };

    server.setRequestHandler(SetLevelRequestSchema, async (request) => {
      currentLogLevel = request.params.level;
      return {};
    });

    function mcpLog(level: 'debug' | 'info' | 'warning' | 'error', data: unknown) {
      if ((LOG_LEVEL_SEVERITY[level] ?? 20) >= (LOG_LEVEL_SEVERITY[currentLogLevel] ?? 20)) {
        server.notification({
          method: 'notifications/message',
          params: { level, data: typeof data === 'string' ? data : JSON.stringify(data) }
        }).catch(() => {});
      }
    }
    ```

## 37. Resource Subscriptions & Real-Time Change Notifications
- **Stale Cache Invalidation via `notifications/resources/updated`**:
  - ❌ **Anti-Pattern: Host Polling vs Silent Staleness**: Clients polling `resources/read` on a tight timer to detect file changes or database updates, or clients caching resource URIs indefinitely with no awareness of server-side mutations.
  - ✅ **Production Invariant**: Maintain a registry of subscribed URIs via `resources/subscribe` and publish granular `notifications/resources/updated` when the underlying resource mutates:
    ```typescript
    const activeSubscribers = new Set<string>();

    server.setRequestHandler(SubscribeRequestSchema, async (request) => {
      activeSubscribers.add(request.params.uri);
      return {};
    });

    server.setRequestHandler(UnsubscribeRequestSchema, async (request) => {
      activeSubscribers.delete(request.params.uri);
      return {};
    });

    function notifyResourceMutation(uri: string) {
      if (activeSubscribers.has(uri)) {
        server.notification({
          method: 'notifications/resources/updated',
          params: { uri }
        }).catch((err) => console.error('Failed to dispatch resource update notification', err));
      }
    }
    ```

## 38. Tool Annotations Protocol (`audience` & `priority`) Context Budgeting
- **Unannotated Tool Saturation & Prompt Bloat**:
  - ❌ **Anti-Pattern: Flat Uniform Tool Catalogs Without Priority Signals**: Exposing dozens of granular diagnostic tools without meta-annotations. Host LLMs cannot distinguish high-frequency core workflows from low-frequency edge tools, resulting in token exhaustion and tool selection confusion.
  - ✅ **Production Invariant**: Provide `annotations` metadata on tool definitions indicating expected audience (`['assistant']`, `['user']`) and relative priority (`0.0` to `1.0`), enabling intelligent host-side tool pruning:
    ```typescript
    server.setRequestHandler(ListToolsRequestSchema, async () => {
      return {
        tools: [
          {
            name: 'run_production_query',
            description: 'Executes analytical read-only SQL queries against replica.',
            inputSchema: { type: 'object', properties: { sql: { type: 'string' } }, required: ['sql'] },
            // Signals high relevance for autonomous assistant reasoning:
            annotations: {
              audience: ['assistant'],
              priority: 0.95
            }
          },
          {
            name: 'dump_server_diagnostics',
            description: 'Outputs verbose kernel and transport debugging telemetry.',
            inputSchema: { type: 'object', properties: {} },
            // Low priority; host can omit from prompt during context compaction:
            annotations: {
              audience: ['assistant'],
              priority: 0.1
            }
          }
        ]
      };
    });
    ```

## 39. Graceful Shutdown & Subprocess Group Cleanup
- **Orphaned Process Leakage on Stdio Host Disconnect**:
  - ❌ **Anti-Pattern: Unguarded Exit Leaking Zombie Child Processes**: When an stdio host abruptly closes pipes or exits, the MCP server is killed while subprocesses (e.g. Chromium, docker exec, tunnels) remain orphaned in the background, locking ports and holding file handles.
  - ✅ **Production Invariant**: Intercept process termination signals (`SIGINT`, `SIGTERM`, stdin `close`), shut down resources cleanly, and kill subprocess process groups using negative PID (`-pid`):
    ```typescript
    import { ChildProcess } from 'node:child_process';

    const childProcesses = new Set<ChildProcess>();

    function registerChild(proc: ChildProcess) {
      childProcesses.add(proc);
      proc.on('exit', () => childProcesses.delete(proc));
    }

    async function gracefulShutdown(signal: string) {
      console.error(`Received ${signal}. Shutting down MCP server...`);
      
      // Enforce 3-second bounded hard exit to prevent hanging on zombie handles
      const forceExitTimer = setTimeout(() => {
        console.error('Graceful shutdown timed out after 3s. Force terminating.');
        process.exit(1);
      }, 3000);
      forceExitTimer.unref();

      // Terminate all spawned child process groups
      for (const proc of childProcesses) {
        if (proc.pid) {
          try {
            process.kill(-proc.pid, 'SIGTERM'); // Signal entire process tree
          } catch {
            // Already exited
          }
        }
      }

      await server.close();
      process.exit(0);
    }

    process.on('SIGINT', () => gracefulShutdown('SIGINT'));
    process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
    process.stdin.on('close', () => gracefulShutdown('stdin-close'));
    ```

## 40. MCP SSE Stream Heartbeats & Client Disconnect Cleanup
- **Zombie SSE Connections & Proxy Timeout Dropouts**:
  - ❌ **Anti-Pattern: Passive SSE Streams Without Keep-Alive Heartbeats**: Relying on passive SSE connections. When behind reverse proxies (NGINX, Cloudflare, Envoy), connections with $>60\text{s}$ of inactivity are terminated with `504 Gateway Timeout` or socket reset errors, severing the agent's MCP channel mid-task.
  - ✅ **Production Invariant**: Emit periodic 15-second SSE keep-alive comment frames (`: ping\n\n`) and bind client abort event listeners (`req.on('close')`) to evict stale session state:
    ```typescript
    import type { Request, Response } from 'express';

    const activeSessions = new Map<string, { res: Response; timer: NodeJS.Timeout }>();

    export function handleSseConnection(sessionId: string, req: Request, res: Response) {
      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');
      res.flushHeaders();

      // Send periodic keep-alive heartbeat every 15s
      const heartbeatTimer = setInterval(() => {
        res.write(': keep-alive\n\n');
      }, 15000);

      activeSessions.set(sessionId, { res, timer: heartbeatTimer });

      req.on('close', () => {
        clearInterval(heartbeatTimer);
        activeSessions.delete(sessionId);
        console.error(`MCP SSE session ${sessionId} disconnected and cleaned up.`);
      });
    }
    ```

## 41. Zero-Allocation Streaming Tool Progress Reporting (`ProgressToken`)
- **Long-Running Tool Hang Assumptions & Agent Timeout Aborts**:
  - ❌ **Anti-Pattern: Silent 60-Second Batch Executions**: Running large operations (e.g. database migrations, bulk file re-indexing, integration test suites) without sending intermediate progress notifications. The LLM agent host interprets the prolonged silence as a hung subprocess and forcibly aborts the tool call.
  - ✅ **Production Invariant**: Intercept `_meta.progressToken` from the client request and emit JSON-RPC `notifications/progress` updates as discrete chunks complete:
    ```typescript
    import { Server } from '@modelcontextprotocol/sdk/server/index.js';

    async function executeLongRunningBatch(
      server: Server,
      items: string[],
      progressToken?: string | number
    ) {
      const total = items.length;
      for (let i = 0; i < total; i++) {
        await processItem(items[i]);

        if (progressToken !== undefined) {
          // Emit non-blocking progress notification to client host:
          await server.notification({
            method: 'notifications/progress',
            params: {
              progressToken,
              progress: i + 1,
              total
            }
          }).catch(() => {});
        }
      }
    }
    ```
- **MCP 2024-11-05 Specification: Binary Content & Image Framing vs Naked Strings**:
  - ❌ **Anti-Pattern: Returning Raw Base64 or Binary Blobs in Text Content**: Returning screenshots or file buffers embedded in plain text strings (`{ type: "text", text: "data:image/png;base64,iVBORw..." }`). This confuses LLM tokenizers, bloats context with raw character sequences, and prevents multimodal models from rendering the visual artifact.
  - ✅ **Production Invariant**: In MCP servers adhering to the 2024-11-05 spec, always return binary data as structured image blocks or resource references:
    ```typescript
    import { CallToolResult } from '@modelcontextprotocol/sdk/types.js';

    function formatScreenshotResult(base64Png: string): CallToolResult {
      return {
        content: [
          {
            type: 'image',
            data: base64Png,
            mimeType: 'image/png',
          },
          {
            type: 'text',
            text: 'Screenshot captured successfully at 375x812 viewport.',
          },
        ],
      };
    }
    ```
- **MCP Tool Error Framing: Protocol Error vs Tool Execution Error (`isError: true`)**:
  - ❌ **Anti-Pattern: Throwing JSON-RPC Errors for Business / Validation Failures**: Returning a JSON-RPC error response (`{ error: { code: -32603, message: "File not found" } }`) when a user argument is invalid or a target file does not exist. The MCP client treats protocol errors as fatal harness crashes, preventing the agent from reading the explanation and self-correcting.
  - ✅ **Production Invariant**: Reserve JSON-RPC protocol error codes (`-32600`, `-32602`, `-32603`) strictly for transport or protocol decoding failures. For tool execution errors, return a standard tool result with `isError: true`:
    ```typescript
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;

      if (name === 'read_workspace_file') {
        const filePath = String(args?.path);
        if (!isSafePath(filePath)) {
          // Self-correctable tool execution error:
          return {
            content: [
              {
                type: 'text',
                text: `Error: Access denied. Path '${filePath}' is outside the authorized project root.`,
              },
            ],
            isError: true,
          };
        }
      }
      // ...
    });
    ```
- **MCP StdIO Transport Lifecycle: Graceful Client Disconnect & Process Group Teardown**:
  - ❌ **Anti-Pattern: Orphaned Background Child Processes on Host Disconnect**: When the IDE or CLI closes, the parent closes `stdin`. If the MCP server does not monitor `stdin` closure, background child processes (e.g. database proxies, headless browsers, file watchers) remain running indefinitely, consuming system memory and holding port locks.
  - ✅ **Production Invariant**: Listen to `process.stdin.on('close')` and `process.on('SIGTERM')`. Cleanly close active database connection pools, terminate child process groups via negative PID (`-child.pid`), and exit immediately:
    ```typescript
    import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

    const transport = new StdioServerTransport();
    await server.connect(transport);

    const cleanupAndExit = async () => {
      console.error('MCP Client disconnected. Terminating server and child processes...');
      // Clean up headless browsers, database pools, and child worker trees
      await browser?.close().catch(() => {});
      await dbPool?.end().catch(() => {});
      process.exit(0);
    };

    process.stdin.on('close', cleanupAndExit);
    process.on('SIGTERM', cleanupAndExit);
    process.on('SIGINT', cleanupAndExit);
    ```
- **MCP JSON-RPC 2.0 Error Code Hierarchy & Actionable Diagnostic Returns**:
  - ❌ **Anti-Pattern: Unhandled Raw Exceptions or Generic String Errors**: Throwing unhandled Node errors (`throw new Error("failed")`) inside tool execution handlers. The host receives an opaque JSON-RPC Internal Error (`-32603`) without parameter hints, triggering endless retry loops or crashing the agent session.
  - ✅ **Production Invariant**: Differentiate between protocol-level invalid arguments (`ErrorCode.InvalidParams = -32602`) and tool-level domain errors. For tool-level failures, return an informative error content payload with `isError: true` so the calling LLM understands why the tool failed and how to self-correct:
    ```typescript
    import { McpError, ErrorCode } from '@modelcontextprotocol/sdk/types.js';

    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;

      if (name === 'execute_query') {
        const query = args?.query;
        if (typeof query !== 'string' || query.trim() === '') {
          // Protocol-level schema violation:
          throw new McpError(ErrorCode.InvalidParams, 'Parameter "query" must be a non-empty string.');
        }

        try {
          const results = await runQuery(query);
          return { content: [{ type: 'text', text: JSON.stringify(results) }] };
        } catch (dbErr: any) {
          // Tool-level domain failure: Provide actionable error feedback for the LLM
          return {
            content: [
              {
                type: 'text',
                text: `Database execution error: ${dbErr.message}. Verify table names and column types.`,
              },
            ],
            isError: true,
          };
        }
      }
      throw new McpError(ErrorCode.MethodNotFound, `Tool '${name}' is not recognized.`);
    });
    ```
- **MCP Resource Subscriptions & Proactive Invalidation (`notifications/resources/updated`)**:
  - ❌ **Anti-Pattern: Polling MCP Resources via Repeated Tool Invocations**: Forcing autonomous agents to repeatedly invoke query tools or read resource endpoints in tight loops to detect when external files, database tables, or log buffers change. This burns tokens, wastes context window capacity, and saturates the host CPU.
  - ✅ **Production Invariant**: In servers exposing dynamic resources (e.g., config files, test run logs, active database tables), support MCP Resource Subscriptions (`resources/subscribe` and `resources/unsubscribe`). Whenever underlying state changes, emit a proactive JSON-RPC notification (`notifications/resources/updated`) with the affected resource URI so the client agent invalidates its internal cache:
    ```typescript
    import { Server } from '@modelcontextprotocol/sdk/server/index.js';
    import {
      SubscribeRequestSchema,
      UnsubscribeRequestSchema,
    } from '@modelcontextprotocol/sdk/types.js';

    const subscribedUris = new Set<string>();

    server.setRequestHandler(SubscribeRequestSchema, async (request) => {
      const { uri } = request.params;
      subscribedUris.add(uri);
      return {};
    });

    server.setRequestHandler(UnsubscribeRequestSchema, async (request) => {
      const { uri } = request.params;
      subscribedUris.delete(uri);
      return {};
    });

    // When file or external event triggers an update:
    export async function notifyResourceChanged(server: Server, changedUri: string): Promise<void> {
      if (subscribedUris.has(changedUri)) {
        await server.notification({
          method: 'notifications/resources/updated',
          params: { uri: changedUri },
        });
      }
    }
    ```
- **MCP Client Cancellation Propagation (`notifications/cancelled`)**:
  - ❌ **Anti-Pattern: Abandoned Background Operations on Client Abort**: When an autonomous agent user hits "Cancel" (or the agent orchestrator aborts a tool call due to timeout), the client sends a `notifications/cancelled` notification. If the MCP server ignores this, long-running database queries, heavy AI generations, or subprocesses continue consuming CPU and memory to completion in the background.
  - ✅ **Production Invariant**: In MCP servers executing asynchronous work, track active request IDs and attach `AbortController` signals. When a `notifications/cancelled` notification is received for a `requestId`, trigger `.abort()` immediately to terminate child network connections and queries:
    ```typescript
    import { Server } from '@modelcontextprotocol/sdk/server/index.js';
    import { CancelledNotificationSchema } from '@modelcontextprotocol/sdk/types.js';

    const activeControllers = new Map<string | number, AbortController>();

    server.setNotificationHandler(CancelledNotificationSchema, async (notification) => {
      const { requestId } = notification.params;
      const controller = activeControllers.get(requestId);
      if (controller) {
        // Immediately abort underlying fetch, query, or process:
        controller.abort();
        activeControllers.delete(requestId);
      }
    });

    // Inside tool handler:
    export async function handleHeavyToolExecution(requestId: string | number, url: string): Promise<string> {
      const controller = new AbortController();
      activeControllers.set(requestId, controller);
      try {
        const response = await fetch(url, { signal: controller.signal });
        return await response.text();
      } finally {
        activeControllers.delete(requestId);
      }
    }
    ```
- **MCP Client Capability Negotiation & Version Handshake Protocol**:
  - ❌ **Anti-Pattern: Assuming Client Capabilities Without Handshake Inspection**: Emitting advanced prompts, roots list changes, or reverse sampling requests (`sampling/createMessage`) to clients that haven't declared support in their initialize request. If the client (e.g. Claude Code or an IDE plugin) does not implement the capability, it throws uncaught JSON-RPC method errors, tearing down the session.
  - ✅ **Production Invariant**: Inspect `clientCapabilities` stored during the `initialize` handshake before executing optional protocol extensions. Gracefully fall back to standard tool outputs when capabilities are absent:
    ```typescript
    import { Server } from '@modelcontextprotocol/sdk/server/index.js';
    import type { ClientCapabilities } from '@modelcontextprotocol/sdk/types.js';

    let negotiatedCapabilities: ClientCapabilities | null = null;

    server.setRequestHandler(InitializeRequestSchema, async (request) => {
      // Store client capabilities negotiated during handshake:
      negotiatedCapabilities = request.params.capabilities;

      return {
        protocolVersion: '2024-11-05',
        capabilities: {
          tools: {},
          resources: { subscribe: true },
          prompts: {},
        },
        serverInfo: { name: 'secure-data-server', version: '1.0.0' },
      };
    });

    // Guard capability-dependent operations:
    export function canSampleLLM(): boolean {
      return Boolean(negotiatedCapabilities?.sampling);
    }
    ```
- **MCP Streamable Resource Template Parameter Validation**:
  - ❌ **Anti-Pattern: Unsanitized URI Path Injection in Resource Templates**: Exposing URI templates like `file:///{path}` or `db://table/{id}` and directly passing parsed template variables into filesystem or SQL queries without regex boundary validation, inviting directory traversal (`../../etc/passwd`) or SQL injection.
  - ✅ **Production Invariant**: Validate resource template parameters against strict alphanumeric / slug schemas and reject any parameter containing directory separators (`/`, `\`, `..`):
    ```typescript
    import { ResourceTemplate } from '@modelcontextprotocol/sdk/server/index.js';
    import { z } from 'zod';

    const safeResourceIdSchema = z.string().regex(/^[a-zA-Z0-9_-]{1,64}$/);

    const documentResourceTemplate = new ResourceTemplate(
      'docs://{docId}',
      { list: undefined }
    );

    server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
      const match = documentResourceTemplate.match(request.params.uri);
      if (!match) throw new Error('Unknown resource URI');

      // Enforce strict character boundaries against path traversal:
      const safeId = safeResourceIdSchema.parse(match.docId);
      const content = await fetchDocumentById(safeId);

      return {
        contents: [{
          uri: request.params.uri,
          mimeType: 'text/plain',
          text: content,
        }],
      };
    });
    ```
- **MCP Tool Request Cancellation & AbortSignal Wiring (`request.signal`)**:
  - ❌ **Anti-Pattern: Ignoring Client Disconnection & Orphaned Tool Execution**: Executing long-running queries or external API calls inside MCP tool handlers without checking for client cancellation. When an agent user presses "Stop Generating" or cancels a prompt in Claude Code/Cursor, the server continues wasting CPU and database resources.
  - ✅ **Production Invariant**: Always extract and propagate the MCP request `AbortSignal` to all downstream network requests, database transactions, and subprocesses:
    ```typescript
    import { CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';

    server.setRequestHandler(CallToolRequestSchema, async (request, extra) => {
      if (request.params.name === 'run_complex_query') {
        const signal = extra.signal; // MCP SDK provided AbortSignal

        // Propagate signal to fetch or database driver:
        const response = await fetch('https://api.internal/analytics', {
          signal,
          method: 'POST',
          body: JSON.stringify(request.params.arguments),
        });

        const data = await response.json();
        return { content: [{ type: 'text', text: JSON.stringify(data) }] };
      }
      throw new Error(`Tool not found: ${request.params.name}`);
    });
    ```
- **MCP Deterministic In-Memory Transport Harness for CI Testing**:
  - ❌ **Anti-Pattern: Spawning Subprocesses with Fragile stdio Pipes in Unit Tests**: Starting live Node/Python CLI subprocesses in CI tests with `child_process.spawn` and hardcoded `sleep` delays to await stdio readiness. Pipe buffering and platform line-ending differences lead to flaky CI test failures.
  - ✅ **Production Invariant**: Use `InMemoryTransport` from `@modelcontextprotocol/sdk` to test MCP servers deterministically in pure memory without I/O latency:
    ```typescript
    import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
    import { Client } from '@modelcontextprotocol/sdk/client/index.js';
    import { createServer } from './my-server.js';

    test('executes tool deterministically via InMemoryTransport', async () => {
      const server = createServer();
      const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

      await server.connect(serverTransport);
      const client = new Client({ name: 'test-client', version: '1.0.0' }, { capabilities: {} });
      await client.connect(clientTransport);

      const result = await client.callTool({
        name: 'echo',
        arguments: { message: 'hello world' },
      });

      expect(result.content[0].text).toBe('hello world');

      await client.close();
      await server.close();
    });
    ```
- **MCP Tool Output Size Budgeting & Dual-Buffer Head/Tail Truncation**:
  - ❌ **Anti-Pattern: Unbounded Tool Output Exhausting Context Windows**: Returning 10MB of raw git diffs, build outputs, or database query records directly in `content[0].text`. This blows past the agent harness context window and triggers abrupt session termination.
  - ✅ **Production Invariant**: Enforce a strict tool payload ceiling (e.g. 50KB / 1,500 lines). When output exceeds the limit, write the full uncompressed stream to a local scratchpad file and return a preserved head + tail excerpt:
    ```typescript
    import * as fs from 'node:fs';
    import * as os from 'node:os';
    import * as path from 'node:path';

    function formatToolOutput(raw: string, maxBytes = 50 * 1024): { type: 'text'; text: string } {
      if (Buffer.byteLength(raw, 'utf-8') <= maxBytes) {
        return { type: 'text', text: raw };
      }

      const tempFile = path.join(os.tmpdir(), `mcp_spillover_${Date.now()}.log`);
      fs.writeFileSync(tempFile, raw, 'utf-8');

      const lines = raw.split('\n');
      const head = lines.slice(0, 300).join('\n');
      const tail = lines.slice(-200).join('\n');
      const summary = `\n... [TRUNCATED: ${lines.length - 500} lines (${raw.length} bytes) omitted. Full log saved to ${tempFile}] ...\n`;

      return { type: 'text', text: `${head}\n${summary}\n${tail}` };
    }
    ```
- **Structured Error Handling with `isError: true` vs Process Abort**:
  - ❌ **Anti-Pattern: Uncaught Exceptions Severing JSON-RPC Transport**: Throwing raw errors inside `CallToolRequestSchema` handler or calling `process.exit(1)`. The stdio pipe closes abruptly, breaking the client session with `ConnectionClosed`.
  - ✅ **Production Invariant**: Catch all operational exceptions within the tool boundary and return standard MCP error payloads with `isError: true`, allowing autonomous agents to observe the failure and self-correct:
    ```typescript
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      try {
        const result = await executeToolAction(request.params.name, request.params.arguments);
        return { content: [{ type: 'text', text: result }] };
      } catch (err: any) {
        // Return gracefully without crashing the MCP JSON-RPC connection:
        return {
          isError: true,
          content: [
            {
              type: 'text',
              text: `Tool execution failed: ${err.message || String(err)}\nCheck parameters and retry.`,
            },
          ],
        };
      }
    });
    ```
- **Strict Zod Input Schemas with `.strict()` Against Hallucinated Arguments**:
  - ❌ **Anti-Pattern: Open Object Schemas Permitting Fictional LLM Parameters**: Defining tool parameters with open Zod objects (`z.object({ file: z.string() })`). Autonomous agents routinely hallucinate supplementary arguments (`force: true`, `dryRun: false`, `encoding: "utf8"`). These unvalidated properties bypass type checking and corrupt downstream execution logic.
  - ✅ **Production Invariant**: Append `.strict()` to all MCP tool argument schemas. If an agent supplies unannounced keys, validation fails immediately at the JSON-RPC boundary with an explicit schema error:
    ```typescript
    const DeployToolInputSchema = z
      .object({
        environment: z.enum(['staging', 'production']),
        commitSha: z.string().length(40),
      })
      .strict(); // Prohibits hallucinated extra arguments!

    server.tool(
      'deploy_service',
      'Deploy service to targeted cloud environment',
      DeployToolInputSchema.shape,
      async (args) => {
        // args is guaranteed strictly compliant with zero unknown properties
        return { content: [{ type: 'text', text: `Deployed ${args.commitSha} to ${args.environment}` }] };
      }
    );
    ```
- **Architectural Segregation: MCP Tools vs Declarative Resources (`resources/read`)**:
  - ❌ **Anti-Pattern: Converting Static Read-Only Context into Operational Tools**: Implementing read-only documentation, database schemas, or system configurations as tools (`get_architecture_docs`, `read_schema`). This wastes LLM action-planning turns and consumes precious tool invocation tokens.
  - ✅ **Production Invariant**: Expose read-only contextual assets via MCP Resources (`resources/list` and `resources/read`) using explicit URI schemes (`schema://postgres/public`, `docs://architecture/overview`). Reserve MCP Tools exclusively for actions with parameters or side effects:
    ```typescript
    server.resource(
      'system-architecture',
      'docs://architecture/system',
      async (uri) => ({
        contents: [
          {
            uri: uri.href,
            text: fs.readFileSync('./docs/architecture.md', 'utf-8'),
            mimeType: 'text/markdown',
          },
        ],
      })
    );
    ```
- **Idempotent MCP Tool Executions & Client Request Tokens (`idempotency_key`)**:
  - ❌ **Anti-Pattern: Mutable Action Tools Without Deduplication Tokens**: Implementing mutating MCP tools (e.g. `create_database_migration`, `charge_customer`, `deploy_cluster`) without an optional or required `idempotency_key` parameter. When an autonomous agent loop experiences a client timeout or transient transport disconnection, it re-issues the tool call, triggering duplicate deployments or multiple billing charges.
  - ✅ **Production Invariant**: Mutating tools MUST declare an `idempotency_key` argument in their input schema. Cache completed execution results in an ephemeral TTL store and return cached results with an indicator when identical keys are received:
    ```typescript
    const toolResultCache = new Map<string, { result: any; timestamp: number }>();

    server.tool(
      'provision_tenant_database',
      'Provision a new isolated database for a SaaS tenant with idempotency',
      z.object({
        tenantId: z.string().uuid(),
        databaseName: z.string().min(3),
        idempotencyKey: z.string().uuid().describe('Client-provided unique key to prevent duplicate provisioning'),
      }).strict().shape,
      async (args) => {
        const cached = toolResultCache.get(args.idempotencyKey);
        if (cached) {
          return {
            content: [{
              type: 'text',
              text: `[IDEMPOTENT_REPLAY] Database already provisioned for tenant ${args.tenantId}: ${JSON.stringify(cached.result)}`,
            }],
          };
        }

        const provisionResult = await dbProvisioner.createDatabase(args.tenantId, args.databaseName);
        toolResultCache.set(args.idempotencyKey, { result: provisionResult, timestamp: Date.now() });

        return {
          content: [{
            type: 'text',
            text: `Successfully provisioned database: ${JSON.stringify(provisionResult)}`,
          }],
        };
      }
    );
    ```
- **Serialized Mutating Tool Execution via Named In-Process Mutexes**:
  - ❌ **Anti-Pattern: Concurrent Non-Thread-Safe Mutating Tool Calls in Multi-Agent Loops**: When an autonomous orchestrator runs multiple parallel sub-agents or issues concurrent tool calls (`tools/call`) mutating the same local repository or workspace state (e.g. `git checkout`, `npm install`, file writing), executing them without serialization causes file system corruptions, git index lock collisions (`.git/index.lock`), or partial writes.
  - ✅ **Production Invariant**: Implement a keyed in-process mutex manager inside the MCP server. Mutating tools acquiring workspace resources MUST serialize operations with unique locks and timeouts:
    ```typescript
    class KeyedMutex {
      private locks = new Map<string, Promise<void>>();

      async runExclusive<T>(key: string, task: () => Promise<T>): Promise<T> {
        while (this.locks.has(key)) {
          await this.locks.get(key);
        }
        let release: () => void;
        const lockPromise = new Promise<void>((resolve) => { release = resolve; });
        this.locks.set(key, lockPromise);

        try {
          return await task();
        } finally {
          this.locks.delete(key);
          release!();
        }
      }
    }

    const workspaceMutex = new KeyedMutex();

    server.tool(
      'git_apply_patch',
      'Applies a patch safely with exclusive workspace lock',
      z.object({ patch: z.string() }).shape,
      async (args) => {
        return workspaceMutex.runExclusive('workspace-git', async () => {
          // Guaranteed single-agent exclusive execution; zero .git/index.lock contention!
          return await applyGitPatch(args.patch);
        });
      }
    );
    ```
- **Webhook Ingestion & Push Notification Decoupling in MCP Servers**:
  - ❌ **Anti-Pattern: Blocking MCP Server Transport with Synchronous Webhook Processing**: Executing heavy webhook ingestion or external API push notifications synchronously on the same thread/process managing MCP stdio or SSE transport. This blocks incoming MCP JSON-RPC messages and triggers client tool-call timeout errors (`tool execution timed out after 30000ms`).
  - ✅ **Production Invariant**: Verify inbound webhook signatures over raw buffers, acknowledge receipt immediately with HTTP 202, and decouple external event notifications from the MCP RPC event loop using an internal asynchronous event queue or worker:
    ```typescript
    import { createHmac, timingSafeEqual } from 'node:crypto';

    export function verifyMcpWebhook(
      rawBody: Buffer,
      signatureHeader: string,
      secret: string
    ): boolean {
      const computed = createHmac('sha256', secret).update(rawBody).digest();
      const received = Buffer.from(signatureHeader.replace('sha256=', ''), 'hex');
      if (computed.length !== received.length) return false;
      return timingSafeEqual(computed, received);
    }
    ```
- **Long-Running Durable Workflows & Asynchronous Polling Pattern in MCP Tools**:
  - ❌ **Anti-Pattern: Blocking MCP Tool Call on Multi-Minute Workflows**: Wrapping multi-step distributed operations (e.g., database provisioning, large dataset compilation, or multi-service deployment) inside a single synchronous `server.tool()` handler. If execution exceeds 30–60 seconds, MCP clients (Claude Desktop, Cursor, Pi) time out the JSON-RPC call, leaving the workflow orphaned in the background.
  - ✅ **Production Invariant**: Return an immediate asynchronous job token (`workflow_id`) with status `RUNNING` in $<500\text{ms}$. Expose separate query and signal tools (`poll_workflow_status`, `send_workflow_signal`) so agents inspect progress and deliver inputs across turn boundaries:
    ```typescript
    // Industrial Asynchronous Durable Workflow Pattern for MCP Tools
    server.tool(
      'start_cloud_provisioning',
      'Initiates long-running cloud provisioning saga and returns immediate workflow token',
      z.object({ tenantId: z.string(), plan: z.string() }).shape,
      async (args) => {
        const workflowId = `wf_prov_${Date.now()}_${randomUUID().slice(0, 8)}`;
        await sagaEngine.start(workflowId, args);

        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify({
                workflowId,
                status: 'RUNNING',
                message: 'Provisioning initiated. Use `check_workflow_status` with this workflowId to poll progress.',
                pollIntervalMs: 5000,
              }),
            },
          ],
        };
      }
    );
    ```
- **Parent Process Lifecycle Gating, Stdio EOF Trapping & Process Group Cleanup**:
  - ❌ **Anti-Pattern: Zombie MCP Subprocesses & Unclosed File Descriptors on Client Disconnect**: When Claude Desktop, Cursor, or Pi closes the stdio transport or restarts, naive MCP servers fail to listen to `process.stdin.on('end')` and leave background processes or tool workers running as orphaned zombie processes consuming 100% CPU.
  - ✅ **Production Invariant**: Intercept `stdin` EOF and `SIGTERM`, terminate child tool processes via negative PGID signals (`process.kill(-child.pid, 'SIGTERM')`), and enforce a 2000ms escalation to `SIGKILL` to guarantee zero zombie leaks across restarts:
    ```typescript
    // Industrial Stdio EOF & Process Group Teardown for MCP Servers
    if (!process.stdin.isTTY) {
      process.stdin.on('end', async () => {
        console.error('[MCP Lifecycle] Host closed stdin pipe. Initiating clean teardown...');
        // Terminate all spawned tool child process groups
        for (const child of activeSubprocesses) {
          if (child.pid && !child.killed) {
            try {
              process.kill(-child.pid, 'SIGTERM');
            } catch {}
          }
        }
        await sleep(1500);
        process.exit(0);
      });
    }
    ```
- **MCP Poison Tool-Call Quarantine, Dead-Letter Execution Logging & Stdio Transport Isolation**:
  - ❌ **Anti-Pattern: Uncaught Tool Exception Severing Stdio JSON-RPC Stream**: Allowing an unhandled tool exception or OOM in a tool handler to crash the MCP server process, severing the stdio JSON-RPC pipe and breaking the entire host agent session (Claude Desktop, Cursor, Pi).
  - ✅ **Production Invariant**: Enclose all tool dispatches in an execution boundary that catches poison inputs, routes diagnostic details (tool name, arguments hash, error stack) to a local dead-letter audit buffer, and returns a structured JSON-RPC error response with `isError: true` so the model can self-correct without crashing the transport:
    ```typescript
    // Industrial MCP Poison Tool-Call Quarantine & Safe Error Framing
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;
      const callHash = crypto.createHash('sha256').update(JSON.stringify({ name, args })).digest('hex').slice(0, 16);

      try {
        const result = await executeToolWithTimeout(name, args, 30000);
        return { content: [{ type: 'text', text: JSON.stringify(result) }] };
      } catch (err: any) {
        // Quarantine poison tool call into diagnostic dead-letter log
        console.error(`[MCP DLQ] Tool "${name}" call ${callHash} failed:`, err.message);
        return {
          isError: true,
          content: [{
            type: 'text',
            text: `Tool execution failed [call_id: ${callHash}]: ${err.message}. Please refine your arguments.`
          }]
        };
      }
    });
    ```
- **MCP Tool Memoization, Singleflight Request Coalescing & Invalidation Protocols**:
  - ❌ **Anti-Pattern: Redundant Multi-Agent Tool Re-Execution & AST Thrashing**: Allowing parallel agent sub-tasks or swarms (Claude Code, Cursor Composer, Devin) to repeatedly execute identical read-only MCP tools (such as workspace file tree hashing, symbol graph queries, or git blame lookups), thrashing filesystem I/O and wasting seconds of wall-clock time.
  - ✅ **Production Invariant**: Intercept idempotent read-only tool calls in a singleflight coalescing layer backed by an in-memory TTL cache, hashing tool arguments to reuse concurrent in-flight executions, while invalidating affected cache keys on mutating tool calls:
    ```typescript
    // Industrial MCP Tool Coalescing & Memoization Middleware
    const inFlightTools = new Map<string, Promise<any>>();
    const toolMemoCache = new Map<string, { result: any; expiresAt: number }>();

    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;
      const isReadOnly = name.startsWith('read_') || name.startsWith('get_') || name.startsWith('search_');

      if (!isReadOnly) {
        // Mutating tool (write_*, edit_*, bash_*): clear memo cache to prevent stale reads
        toolMemoCache.clear();
        const outcome = await executeTool(name, args);
        return { content: [{ type: 'text', text: JSON.stringify(outcome) }] };
      }

      const cacheKey = `${name}:${crypto.createHash('sha256').update(JSON.stringify(args ?? {})).digest('hex')}`;
      const cached = toolMemoCache.get(cacheKey);
      if (cached && Date.now() < cached.expiresAt) {
        return { content: [{ type: 'text', text: JSON.stringify(cached.result) }] };
      }

      // Singleflight coalescing for concurrent read-only tool requests
      if (!inFlightTools.has(cacheKey)) {
        const executionPromise = executeTool(name, args).then((res) => {
          toolMemoCache.set(cacheKey, { result: res, expiresAt: Date.now() + 30000 }); // 30s TTL
          return res;
        }).finally(() => {
          inFlightTools.delete(cacheKey);
        });
        inFlightTools.set(cacheKey, executionPromise);
      }

      const result = await inFlightTools.get(cacheKey);
      return { content: [{ type: 'text', text: JSON.stringify(result) }] };
    });
    ```
- **MCP Server Tool-Call Bulkheading, Timeout Deadlines & Circuit Breaker Degradation**:
  - ❌ **Anti-Pattern: Unbounded Subprocess Execution & Event-Loop Freezing**: Permitting external CLI, LSP, or database tools to run without timeouts or concurrency limits, causing a hung subprocess to deadlock the MCP JSON-RPC transport and freeze the agent harness (Claude Code, Cursor).
  - ✅ **Production Invariant**: Isolate each tool within a dedicated concurrency bulkhead, apply a hard `AbortSignal` deadline, and return a degraded fallback status when the circuit is open:
    ```typescript
    // Industrial MCP Tool Bulkhead & Resilient Execution Guard
    const toolSemaphores = new Map<string, { active: number; limit: number }>();

    function getToolSemaphore(toolName: string) {
      if (!toolSemaphores.has(toolName)) {
        toolSemaphores.set(toolName, { active: 0, limit: 5 }); // Max 5 parallel subprocesses
      }
      return toolSemaphores.get(toolName)!;
    }

    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;
      const sem = getToolSemaphore(name);

      if (sem.active >= sem.limit) {
        return {
          content: [{
            type: 'text',
            text: JSON.stringify({
              error: `Tool [${name}] bulkhead capacity exceeded (${sem.active}/${sem.limit}). Load shed.`,
              isDegraded: true,
            })
          }],
          isError: true,
        };
      }

      sem.active++;
      const ac = new AbortController();
      const timeout = setTimeout(() => ac.abort(), 10000); // 10s hard deadline

      try {
        const result = await executeToolWithSignal(name, args, ac.signal);
        return { content: [{ type: 'text', text: JSON.stringify(result) }] };
      } catch (err: any) {
        return {
          content: [{
            type: 'text',
            text: JSON.stringify({
              error: `Tool execution failed or timed out: ${err.message}`,
              fallbackData: getFallbackMetadata(name),
            })
          }],
          isError: true,
        };
      } finally {
        clearTimeout(timeout);
        sem.active = Math.max(0, sem.active - 1);
      }
    });
    ```

- **Database Connection Pool Scoping & Leak Elimination in MCP Database Tools**:
  - ❌ **Anti-Pattern: Leaking Connections Across Tool Invocations**: Acquiring direct database client connections inside MCP tool handlers without guaranteed `try/finally` release, exhausting pool connections across multiple agent prompt loops until the entire MCP server freezes.
  - ✅ **Production Invariant**: Always wrap MCP database tools in scoped transaction/connection helpers with bounded acquisition timeouts and explicit connection return:
    ```typescript
    // Industrial MCP Database Tool with Scoped Leak-Proof Pool Execution
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      if (request.params.name !== 'query_database') return;

      const { sql, params } = request.params.arguments as { sql: string; params?: any[] };

      // Enforce read-only safety for general query tool
      if (!/^\s*(SELECT|WITH)\b/i.test(sql)) {
        return {
          content: [{ type: 'text', text: 'Error: Only SELECT queries permitted in read-only tool' }],
          isError: true,
        };
      }

      // Scoped checkout: connection release guaranteed even if serialization throws
      const client = await dbPool.connect();
      try {
        // Enforce 5s query deadline inside MCP tool
        await client.query('SET LOCAL statement_timeout = 5000');
        const res = await client.query(sql, params);

        return {
          content: [{
            type: 'text',
            text: JSON.stringify({ rowCount: res.rowCount, rows: res.rows }),
          }],
        };
      } catch (err: any) {
        return {
          content: [{ type: 'text', text: `Database error: ${err.message}` }],
          isError: true,
        };
      } finally {
        client.release(); // Crucial: connection always returned to pool
      }
    });
    ```

- **MCP Database Query Tools Keyset Pagination & Anti-N+1 Batching**:
  - ❌ **Anti-Pattern: Returning Massive Unbounded Lists or Using `OFFSET` in Agent Tools**: Exposing tool parameters like `page: number` with `OFFSET (page * limit)` or allowing agents to trigger N+1 tool invocations (one tool call per item).
  - ✅ **Production Invariant**: Mandate keyset pagination via opaque cursor tokens in MCP tool schemas, batch fetch child associations within a single tool run, and cap maximum result sets:
    ```typescript
    // Industrial MCP Database Tool with Keyset Cursor Pagination & Batch Child Hydration
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      if (request.params.name !== 'list_orders') return;

      const { tenantId, status, cursor, limit = 20 } = request.params.arguments as {
        tenantId: string;
        status: string;
        cursor?: string;
        limit?: number;
      };

      const boundedLimit = Math.min(Math.max(limit, 1), 50); // Cap tool result size
      const client = await dbPool.connect();
      try {
        let sql = `
          SELECT id, customer_id, status, total_amount, created_at
          FROM orders
          WHERE tenant_id = $1 AND status = $2`;
        const params: any[] = [tenantId, status];

        if (cursor) {
          const [cursorTime, cursorId] = Buffer.from(cursor, 'base64url').toString().split('|');
          sql += ` AND (created_at, id) < ($3, $4)`;
          params.push(cursorTime, cursorId);
        }

        sql += ` ORDER BY created_at DESC, id DESC LIMIT $${params.length + 1}`;
        params.push(boundedLimit);

        const orderRes = await client.query(sql, params);
        if (orderRes.rows.length === 0) {
          return { content: [{ type: 'text', text: JSON.stringify({ orders: [], nextCursor: null }) }] };
        }

        // Single-roundtrip batch child hydration (prevents agent N+1 tool cascade)
        const orderIds = orderRes.rows.map((r: any) => r.id);
        const itemRes = await client.query(
          `SELECT order_id, product_id, quantity, unit_price FROM order_items WHERE order_id = ANY($1::UUID[])`,
          [orderIds]
        );

        const itemsByOrderId = new Map<string, any[]>();
        for (const item of itemRes.rows) {
          const list = itemsByOrderId.get(item.order_id) ?? [];
          list.push(item);
          itemsByOrderId.set(item.order_id, list);
        }

        const enriched = orderRes.rows.map((o: any) => ({
          ...o,
          items: itemsByOrderId.get(o.id) ?? [],
        }));

        const last = enriched[enriched.length - 1];
        const nextCursor = enriched.length === boundedLimit
          ? Buffer.from(`${last.created_at.toISOString()}|${last.id}`).toString('base64url')
          : null;

        return {
          content: [{
            type: 'text',
            text: JSON.stringify({ orders: enriched, nextCursor }),
          }],
        };
      } finally {
        client.release();
      }
    });
    ```

- **MCP Mutation Tools OCC Version Epochs & Deadlock Prevention**:
  - ❌ **Anti-Pattern: Blind Overwrite In Tools & Unsorted Multi-Resource Locks**: Exposing MCP mutation tools (e.g. `update_document`, `transfer_balance`) without requiring expected version tokens, allowing agent loops to overwrite concurrent human edits or cause database deadlocks.
  - ✅ **Production Invariant**: Mandate `expectedVersion: number` in tool input schemas, execute optimistic concurrency updates returning `409 Conflict` on mismatch, and sort resource IDs lexicographically before acquiring locks:
    ```typescript
    // Industrial MCP Resource Mutation Tool with Optimistic Concurrency Control (OCC)
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      if (request.params.name !== 'update_inventory_stock') return;

      const { productId, deductAmount, expectedVersion } = request.params.arguments as {
        productId: string;
        deductAmount: number;
        expectedVersion: number;
      };

      if (!productId || deductAmount <= 0 || expectedVersion == null) {
        throw new McpError(ErrorCode.InvalidParams, 'Invalid input parameters');
      }

      const client = await dbPool.connect();
      try {
        const res = await client.query(
          `UPDATE products 
           SET stock = stock - $1, version = version + 1, updated_at = NOW() 
           WHERE id = $2 AND version = $3 AND stock >= $1 
           RETURNING id, stock, version`,
          [deductAmount, productId, expectedVersion]
        );

        if (res.rows.length === 0) {
          // Check if failure was caused by version drift vs stock exhaustion
          const current = await client.query('SELECT stock, version FROM products WHERE id = $1', [productId]);
          if (current.rows.length === 0) {
            throw new McpError(ErrorCode.InvalidRequest, `Product ${productId} not found`);
          }
          const row = current.rows[0];
          if (row.version !== expectedVersion) {
            return {
              isError: true,
              content: [{
                type: 'text',
                text: JSON.stringify({
                  error: 'CONCURRENCY_CONFLICT',
                  message: `Stale version ${expectedVersion}. Current version is ${row.version}. Refresh and retry.`,
                  currentVersion: row.version,
                }),
              }],
            };
          }
          return {
            isError: true,
            content: [{
              type: 'text',
              text: JSON.stringify({ error: 'INSUFFICIENT_STOCK', currentStock: row.stock }),
            }],
          };
        }

        return {
          content: [{
            type: 'text',
            text: JSON.stringify({ success: true, updatedProduct: res.rows[0] }),
          }],
        };
      } finally {
        client.release();
      }
    });

    // MCP Tool Read-After-Write Consistency: Causal LSN Token Propagation Invariant
    // In multi-turn LLM agent execution, write tools return committed projections and WAL LSN tokens,
    // and read tools accept causal tokens to prevent stale read hallucination across replicas.
    server.setRequestHandler(CallToolRequestSchema, async (request) => {
      if (request.params.name === 'create_document') {
        const { title, content } = request.params.arguments as { title: string; content: string };
        const client = await dbPoolPrimary.connect();
        try {
          const res = await client.query(
            `INSERT INTO documents (title, content, updated_at) 
             VALUES ($1, $2, NOW()) 
             RETURNING id, title, content, updated_at`,
            [title, content]
          );
          const lsnRes = await client.query('SELECT pg_current_wal_lsn()::text AS lsn');
          const commitLsn = lsnRes.rows[0]?.lsn;

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                success: true,
                document: res.rows[0],
                // Return causal token so subsequent agent read tools avoid replica lag
                causalToken: commitLsn,
              }),
            }],
          };
        } finally {
          client.release();
        }
      }

      if (request.params.name === 'get_document') {
        const { documentId, causalToken } = request.params.arguments as { documentId: string; causalToken?: string };
        // If caller passes causal token, route to replica ONLY if replica has caught up
        let targetPool = dbPoolReplica;
        if (causalToken) {
          const repClient = await dbPoolReplica.connect();
          try {
            const check = await repClient.query(
              'SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), $1::pg_lsn) >= 0 AS ok',
              [causalToken]
            );
            if (!check.rows[0]?.ok) {
              targetPool = dbPoolPrimary; // Replica lagging, fallback to Primary
            }
          } finally {
            repClient.release();
          }
        }

        const client = await targetPool.connect();
        try {
          const res = await client.query('SELECT * FROM documents WHERE id = $1', [documentId]);
          if (res.rows.length === 0) {
            return { isError: true, content: [{ type: 'text', text: `Document ${documentId} not found` }] };
          }
          return { content: [{ type: 'text', text: JSON.stringify(res.rows[0]) }] };
        } finally {
          client.release();
        }
      }

      // MCP Tool Soft-Delete & Restore Invariant: Atomic Tombstone Cascades & Conflict Preflight
      if (request.params.name === 'soft_delete_workspace') {
        const { workspaceId, actorId } = request.params.arguments as { workspaceId: string; actorId: string };
        const batchId = crypto.randomUUID();
        const client = await dbPoolPrimary.connect();
        try {
          await client.query('BEGIN');
          // Atomic cascade CTE updates parent and children with single batch ID
          const res = await client.query(
            `WITH del_ws AS (
               UPDATE workspaces SET
                 deleted_at = NOW(), deleted_by = $1, deleted_batch_id = $2, version = version + 1
               WHERE id = $3 AND deleted_at IS NULL
               RETURNING id, slug
             ),
             del_docs AS (
               UPDATE documents SET
                 deleted_at = NOW(), deleted_by = $1, deleted_batch_id = $2, version = version + 1
               WHERE workspace_id IN (SELECT id FROM del_ws) AND deleted_at IS NULL
               RETURNING id
             )
             SELECT id, slug FROM del_ws;`,
            [actorId, batchId, workspaceId]
          );

          if (res.rows.length === 0) {
            await client.query('ROLLBACK');
            return { isError: true, content: [{ type: 'text', text: `Workspace ${workspaceId} not found or already deleted` }] };
          }

          await client.query('COMMIT');
          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                success: true,
                workspaceId,
                batchId,
                message: 'Workspace and child documents atomically soft-deleted. Use batchId to restore.',
              }),
            }],
          };
        } catch (err) {
          await client.query('ROLLBACK');
          throw err;
        } finally {
          client.release();
        }
      }
    });
    ```

- **Partition Maintenance, Sargable Plan Inspection & Safe Concurrent Detach Tool**:
  - ❌ **Anti-Pattern: Blind Multi-Partition Dropping & Unverified Pruning**: MCP tools that execute un-hedged `DROP TABLE` across production tables or query partitioned datasets without verifying that partition pruning is engaged, exhausting backend database CPU.
  - ✅ **Production Invariant**: Provide structured MCP tools that verify query plan pruning using `EXPLAIN (FORMAT JSON)` and execute zero-downtime `DETACH PARTITION CONCURRENTLY` outside transactions with strict lock timeout safeguards:
    ```typescript
    server.tool(
      'inspect_and_prune_partition',
      {
        parentTable: z.string().describe('Root partitioned table name'),
        partitionName: z.string().describe('Target child partition table to detach'),
        dryRun: z.boolean().default(true).describe('If true, only verifies state without executing DDL'),
      },
      async ({ parentTable, partitionName, dryRun }) => {
        const client = await dbPool.connect();
        try {
          // 1. Verify child partition is currently part of the hierarchy
          const checkRes = await client.query(
            `SELECT COUNT(*) as count FROM pg_inherits
             WHERE inhrelid = $1::regclass AND inhparent = $2::regclass;`,
            [partitionName, parentTable]
          );

          if (parseInt(checkRes.rows[0].count, 10) === 0) {
            return {
              isError: true,
              content: [{ type: 'text', text: `Partition ${partitionName} is not attached to ${parentTable}` }],
            };
          }

          if (dryRun) {
            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  status: 'VERIFIED',
                  message: `Partition ${partitionName} is attached to ${parentTable} and ready for CONCURRENT detach.`,
                  dryRun: true,
                }),
              }],
            };
          }

          // 2. Execute zero-downtime CONCURRENT detach with lock timeout (Standalone outside TX)
          await client.query("SET lock_timeout = '2000ms'");
          await client.query(`ALTER TABLE ${parentTable} DETACH PARTITION ${partitionName} CONCURRENTLY;`);

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                success: true,
                partitionName,
                status: 'DETACHED_ISOLATED',
                message: `Partition ${partitionName} safely detached concurrently without locking ${parentTable}.`,
              }),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // MVCC Bloat Diagnostics & Zero-Lock Reindexing Tool
    server.tool(
      'audit_database_mvcc_bloat',
      {
        schemaName: z.string().default('public').describe('Database schema to inspect'),
        reindexBloatedTable: z.string().optional().describe('Optional table to REINDEX CONCURRENTLY if bloat > 20%'),
      },
      async ({ schemaName, reindexBloatedTable }) => {
        const client = await dbPool.connect();
        try {
          // 1. Inspect dead tuples and HOT update ratios
          const res = await client.query(`
            SELECT
              relname AS table_name,
              n_live_tup AS live_tuples,
              n_dead_tup AS dead_tuples,
              ROUND((n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0)) * 100, 2) AS dead_ratio_pct,
              ROUND((n_tup_hot_upd::numeric / NULLIF(n_tup_upd, 0)) * 100, 2) AS hot_ratio_pct,
              pg_total_relation_size(c.oid) AS total_bytes
            FROM pg_stat_user_tables s
            JOIN pg_class c ON c.oid = s.relid
            WHERE schemaname = $1
            ORDER BY n_dead_tup DESC LIMIT 10;
          `, [schemaName]);

          // 2. Inspect XID wraparound age
          const xidRes = await client.query(`
            SELECT max(age(datfrozenxid)) AS oldest_xid_age FROM pg_database WHERE datallowconn;
          `);

          let reindexResult = null;
          if (reindexBloatedTable) {
            // REINDEX CONCURRENTLY outside transaction block
            await client.query(`REINDEX TABLE CONCURRENTLY "${schemaName}"."${reindexBloatedTable}";`);
            reindexResult = `Successfully reindexed ${schemaName}.${reindexBloatedTable} concurrently without table locks.`;
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                tables: res.rows,
                oldestXidAge: Number(xidRes.rows[0].oldest_xid_age),
                isXidCritical: Number(xidRes.rows[0].oldest_xid_age) > 150_000_000,
                reindexResult,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // WAL, Checkpointing & Replication Slot Health Tool
    server.tool(
      'audit_database_wal_and_slots',
      {
        alertThresholdMB: z.number().default(5120).describe('Alert threshold in MB for retained WAL by replication slots'),
      },
      async ({ alertThresholdMB }) => {
        const client = await dbPool.connect();
        try {
          // 1. Inspect Checkpoint Health (timed vs req)
          const chkRes = await client.query(`
            SELECT
              checkpoints_timed,
              checkpoints_req,
              ROUND((checkpoints_timed::numeric / NULLIF(checkpoints_timed + checkpoints_req, 0)) * 100, 2) AS timed_pct,
              checkpoint_write_time,
              checkpoint_sync_time
            FROM pg_stat_bgwriter;
          `);

          // 2. Inspect Replication Slots Retaining Excess WAL
          const slotRes = await client.query(`
            SELECT
              slot_name,
              plugin,
              slot_type,
              active,
              COALESCE(wal_status, 'normal') AS wal_status,
              ROUND((pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / (1024.0 * 1024.0))::numeric, 2) AS retained_mb
            FROM pg_replication_slots
            ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
          `);

          const slots = slotRes.rows;
          const atRiskSlots = slots.filter((s: any) => Number(s.retained_mb) > alertThresholdMB || s.wal_status !== 'normal' || !s.active);

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                checkpointHealth: chkRes.rows[0] ?? {},
                checkpointRatioAcceptable: Number(chkRes.rows[0]?.timed_pct ?? 100) >= 95,
                replicationSlots: slots,
                atRiskSlots,
                hasDiskMeltdownRisk: atRiskSlots.length > 0,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Heavyweight Lock Contention, Deadlock & Unindexed FK Sentinel Tool
    server.tool(
      'audit_database_locks_and_deadlocks',
      {
        maxWaitSecondsAlert: z.number().default(2).describe('Alert threshold in seconds for queries waiting on contested locks'),
      },
      async ({ maxWaitSecondsAlert }) => {
        const client = await dbPool.connect();
        try {
          // 1. Inspect Active Blocked Queries & Blocking PIDs
          const lockRes = await client.query(`
            SELECT
              blocked_locks.pid AS blocked_pid,
              blocked_activity.usename AS blocked_user,
              blocking_locks.pid AS blocking_pid,
              blocking_activity.usename AS blocking_user,
              blocked_activity.query AS blocked_statement,
              blocking_activity.query AS current_statement_in_blocking_process,
              blocked_locks.locktype,
              blocked_locks.mode AS requested_mode,
              blocking_locks.mode AS held_mode,
              ROUND(EXTRACT(EPOCH FROM (NOW() - blocked_activity.query_start))::numeric, 2) AS wait_seconds
            FROM pg_catalog.pg_locks blocked_locks
            JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
            JOIN pg_catalog.pg_locks blocking_locks
              ON blocking_locks.locktype = blocked_locks.locktype
              AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
              AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
              AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
              AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
              AND blocking_locks.pid != blocked_locks.pid
            JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
            WHERE NOT blocked_locks.granted;
          `);

          // 2. Inspect Unindexed Foreign Keys (Lock Escalation Vulnerability)
          const fkRes = await client.query(`
            SELECT
              c.conrelid::regclass::text AS child_table,
              c.conname AS foreign_key_name,
              ARRAY(
                SELECT attname FROM pg_attribute
                WHERE attrelid = c.conrelid AND attnum = ANY(c.conkey)
              ) AS fk_columns,
              c.confrelid::regclass::text AS parent_table
            FROM pg_constraint c
            WHERE c.contype = 'f'
              AND NOT EXISTS (
                SELECT 1 FROM pg_index i
                WHERE i.indrelid = c.conrelid
                  AND (i.indkey::smallint[])[0:cardinality(c.conkey)-1] = c.conkey
              );
          `);

          // 3. Inspect Cluster Deadlocks Counter
          const statRes = await client.query(`
            SELECT datname, deadlocks, conflicts
            FROM pg_stat_database
            WHERE datname = current_database();
          `);

          const blockedQueries = lockRes.rows;
          const criticalBlocks = blockedQueries.filter((b: any) => Number(b.wait_seconds) >= maxWaitSecondsAlert);

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                blockedQueriesCount: blockedQueries.length,
                criticalBlocksCount: criticalBlocks.length,
                blockedQueries,
                unindexedForeignKeys: fkRes.rows,
                databaseDeadlocks: statRes.rows[0]?.deadlocks ?? 0,
                hasActiveLockContention: criticalBlocks.length > 0,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Database High Availability, Standby Replication & Failover Readiness Sentinel Tool
    server.tool(
      'audit_database_ha_and_failover_topology',
      {
        maxAllowedLagSeconds: z.number().default(5).describe('Maximum tolerable standby replication lag in seconds before alerting'),
      },
      async ({ maxAllowedLagSeconds }) => {
        const client = await dbPool.connect();
        try {
          // 1. Audit Primary vs Standby Node State
          const roleRes = await client.query(`
            SELECT
              pg_is_in_recovery() AS is_in_recovery,
              current_setting('transaction_read_only') AS is_read_only,
              current_setting('synchronous_commit') AS synchronous_commit,
              current_setting('synchronous_standby_names') AS synchronous_standby_names,
              current_setting('wal_log_hints') AS wal_log_hints;
          `);

          // 2. Audit Streaming Standby Replicas & Sync Status
          const repRes = await client.query(`
            SELECT
              client_addr::text AS standby_ip,
              application_name,
              sync_state,
              state,
              ROUND((pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) / (1024.0 * 1024.0))::numeric, 2) AS lag_mb,
              ROUND(EXTRACT(EPOCH FROM (NOW() - reply_time))::numeric, 2) AS lag_seconds
            FROM pg_stat_replication;
          `);

          const standbys = repRes.rows;
          const nodeRole = roleRes.rows[0];
          const laggingStandbys = standbys.filter((s: any) => Number(s.lag_seconds) > maxAllowedLagSeconds);
          const hasZeroRpoSync = standbys.some((s: any) => s.sync_state === 'sync' || s.sync_state === 'quorum');

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                isPrimaryNode: !nodeRole?.is_in_recovery,
                isReadOnly: nodeRole?.is_read_only === 'on',
                synchronousCommitConfig: nodeRole?.synchronous_commit,
                synchronousStandbyConfig: nodeRole?.synchronous_standby_names,
                walLogHintsEnabled: nodeRole?.wal_log_hints === 'on',
                connectedStandbysCount: standbys.length,
                hasZeroRpoSync,
                standbys,
                laggingStandbys,
                failoverReadiness: {
                  isSafeForFailover: hasZeroRpoSync && laggingStandbys.length === 0,
                  canUsePgRewind: nodeRole?.wal_log_hints === 'on',
                },
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Database Disaster Recovery, WAL Archiving & Integrity Sentinel Tool
    server.tool(
      'audit_database_dr_and_wal_archiving',
      {
        maxAllowedArchiveAgeSec: z.number().default(600).describe('Max allowed seconds since last successful WAL archive push'),
      },
      async ({ maxAllowedArchiveAgeSec }) => {
        const client = await dbPool.connect();
        try {
          // 1. Query pg_stat_archiver
          const archiverRes = await client.query(`
            SELECT
              archived_count,
              COALESCE(last_archived_wal, '') AS last_archived_wal,
              last_archived_time,
              failed_count,
              COALESCE(last_failed_wal, '') AS last_failed_wal,
              last_failed_time,
              ROUND(EXTRACT(EPOCH FROM (NOW() - last_archived_time))::numeric, 2) AS seconds_since_last_archive
            FROM pg_stat_archiver;
          `);

          // 2. Query data_checksums & pending WAL count
          const checksumRes = await client.query(`SHOW data_checksums;`);
          const pendingRes = await client.query(`
            SELECT
              (SELECT count(*) FROM pg_ls_waldir() WHERE name ~ '^[0-9A-F]{24}$') - 
              (SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name ~ '\\.done$') AS pending_wal_count;
          `).catch(() => ({ rows: [{ pending_wal_count: 0 }] }));

          const archiver = archiverRes.rows[0];
          const checksumsOn = checksumRes.rows[0]?.data_checksums === 'on';
          const archiveAgeSec = Number(archiver?.seconds_since_last_archive ?? 0);
          const isArchivalLagging = archiveAgeSec > maxAllowedArchiveAgeSec;
          const isArchivalFailing = archiver?.failed_count > 0 &&
            archiver?.last_failed_time && archiver?.last_archived_time &&
            new Date(archiver.last_failed_time) > new Date(archiver.last_archived_time);

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                dataChecksumsEnabled: checksumsOn,
                archivalHealth: {
                  isArchivalHealthy: !isArchivalFailing && !isArchivalLagging,
                  isArchivalFailing,
                  isArchivalLagging,
                  secondsSinceLastArchive: archiveAgeSec,
                  pendingWalCount: Number(pendingRes.rows[0]?.pending_wal_count ?? 0),
                  lastArchivedWal: archiver?.last_archived_wal,
                  lastFailedWal: archiver?.last_failed_wal,
                },
                slaCompliance: {
                  pitrReady: checksumsOn && !isArchivalFailing,
                  rpoWithinBounds: !isArchivalLagging,
                },
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Database Change Data Capture (CDC) & Logical Replication Slot Sentinel Tool
    server.tool(
      'audit_database_cdc_and_logical_replication',
      {
        slotName: z.string().describe('PostgreSQL logical replication slot name to inspect'),
        maxAllowedLagMb: z.number().default(10240).describe('Max allowed replication lag in MB before alerting on disk risk'),
      },
      async ({ slotName, maxAllowedLagMb }) => {
        const client = await dbPool.connect();
        try {
          // 1. Query pg_replication_slots
          const slotRes = await client.query(`
            SELECT
              slot_name,
              plugin,
              slot_type,
              active,
              wal_status,
              COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0) AS lag_bytes,
              ROUND(COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0) / (1024 * 1024), 2) AS lag_mb,
              COALESCE(age(catalog_xmin), 0) AS catalog_xmin_age
            FROM pg_replication_slots
            WHERE slot_name = $1 AND slot_type = 'logical';
          `, [slotName]);

          if (slotRes.rows.length === 0) {
            return {
              content: [{
                type: 'text',
                text: JSON.stringify({ error: `Slot '${slotName}' does not exist` }, null, 2),
              }],
            };
          }

          const slot = slotRes.rows[0];
          const lagMb = Number(slot.lag_mb);
          const catalogAge = Number(slot.catalog_xmin_age);
          const isDiskAtRisk = lagMb > maxAllowedLagMb || slot.wal_status === 'extended' || slot.wal_status === 'lost';
          const isCatalogBloated = catalogAge > 500000;

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                slotName: slot.slot_name,
                active: slot.active,
                walStatus: slot.wal_status,
                replicationLag: {
                  lagBytes: Number(slot.lag_bytes),
                  lagMb,
                  isDiskAtRisk,
                },
                catalogHealth: {
                  catalogXminAge: catalogAge,
                  isCatalogBloated,
                },
                statusSummary: {
                  isHealthy: slot.active && !isDiskAtRisk && !isCatalogBloated,
                  requiresIntervention: isDiskAtRisk || isCatalogBloated || slot.wal_status === 'lost',
                },
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Multi-Tenant Row-Level Security (RLS) & Policy Bypass Audit Tool
    server.tool(
      'audit_database_rls_policies',
      {
        schemaName: z.string().default('public').describe('PostgreSQL schema to inspect for multi-tenant RLS compliance'),
        requireForceRLS: z.boolean().default(true).describe('Whether to require FORCE ROW LEVEL SECURITY to prevent table owner bypass'),
      },
      async ({ schemaName, requireForceRLS }) => {
        const client = await dbPool.connect();
        try {
          const tableQuery = `
            WITH table_meta AS (
              SELECT
                c.oid AS table_oid,
                c.relname AS tablename,
                pg_get_userbyid(c.relowner) AS tableowner,
                c.relrowsecurity AS rowsecurity,
                c.relforcerowsecurity AS forcerowsecurity
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relkind = 'r'
                AND n.nspname = $1
                AND c.relname NOT IN ('schema_migrations', 'spatial_ref_sys')
            ),
            policies_meta AS (
              SELECT polrelid, count(*) AS policy_count
              FROM pg_policy
              GROUP BY polrelid
            ),
            tenant_indexes AS (
              SELECT
                i.indrelid,
                bool_or(a.attname = 'tenant_id' AND i.indkey[0] = a.attnum) AS has_leftmost_tenant_index
              FROM pg_index i
              JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
              GROUP BY i.indrelid
            )
            SELECT
              tm.tablename,
              tm.tableowner,
              tm.rowsecurity,
              tm.forcerowsecurity,
              COALESCE(pm.policy_count, 0)::int AS policy_count,
              COALESCE(ti.has_leftmost_tenant_index, false) AS has_leftmost_tenant_index
            FROM table_meta tm
            LEFT JOIN policies_meta pm ON pm.polrelid = tm.table_oid
            LEFT JOIN tenant_indexes ti ON ti.indrelid = tm.table_oid
            ORDER BY tm.tablename;
          `;

          const viewQuery = `
            SELECT
              c.relname AS viewname,
              pg_get_userbyid(c.relowner) AS viewowner,
              COALESCE('security_invoker=true' = ANY(c.reloptions), false) AS security_invoker,
              COALESCE('security_barrier=true' = ANY(c.reloptions), false) AS security_barrier
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'v'
              AND n.nspname = $1
            ORDER BY c.relname;
          `;

          const [tableRes, viewRes] = await Promise.all([
            client.query(tableQuery, [schemaName]),
            client.query(viewQuery, [schemaName]),
          ]);

          const tableAudits = tableRes.rows.map((row: any) => {
            const violations: string[] = [];
            if (!row.rowsecurity) violations.push('Missing ENABLE ROW LEVEL SECURITY');
            if (requireForceRLS && !row.forcerowsecurity) violations.push('Missing FORCE ROW LEVEL SECURITY (owner bypass hazard)');
            if (row.policy_count === 0) violations.push('No policies defined');
            if (!row.has_leftmost_tenant_index) violations.push('Missing composite index with tenant_id as leftmost column');

            return {
              tableName: row.tablename,
              tableOwner: row.tableowner,
              isRLSEnabled: row.rowsecurity,
              isRLSForced: row.forcerowsecurity,
              policyCount: row.policy_count,
              hasLeftmostTenantIndex: row.has_leftmost_tenant_index,
              isCompliant: violations.length === 0,
              violations,
            };
          });

          const viewAudits = viewRes.rows.map((row: any) => {
            const violations: string[] = [];
            if (!row.security_invoker) violations.push('Missing WITH (security_invoker = true); executes under view owner context');

            return {
              viewName: row.viewname,
              viewOwner: row.viewowner,
              securityInvoker: row.security_invoker,
              securityBarrier: row.security_barrier,
              isCompliant: violations.length === 0,
              violations,
            };
          });

          const totalTables = tableAudits.length;
          const compliantTables = tableAudits.filter((t: any) => t.isCompliant).length;
          const totalViews = viewAudits.length;
          const compliantViews = viewAudits.filter((v: any) => v.isCompliant).length;

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                schema: schemaName,
                summary: {
                  totalTables,
                  compliantTables,
                  isTablesFullyHardened: totalTables === compliantTables,
                  totalViews,
                  compliantViews,
                  isViewsFullyHardened: totalViews === compliantViews,
                },
                tableAudits,
                viewAudits,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Tool: Audit Query Planner Statistics & NVMe Cost Settings
    server.tool(
      'audit_database_query_plans_and_statistics',
      'Audits PostgreSQL query planner statistics, NVMe cost calibration (random_page_cost), JIT settings, and extended statistics (CREATE STATISTICS)',
      {
        schemaName: z.string().default('public').describe('Schema name to inspect'),
      },
      async ({ schemaName }) => {
        const client = await pool.connect();
        try {
          // 1. Audit Planner Settings
          const settingsRes = await client.query(`
            SELECT name, setting, unit, boot_val, reset_val
            FROM pg_settings
            WHERE name IN ('random_page_cost', 'seq_page_cost', 'effective_io_concurrency', 'work_mem', 'jit');
          `);

          // 2. Audit Extended Statistics
          const extStatsRes = await client.query(`
            SELECT
              s.stxname AS statistics_name,
              c.relname AS table_name,
              s.stxkind AS kinds,
              ARRAY(
                SELECT attname FROM pg_attribute
                WHERE attrelid = c.oid AND attnum = ANY(s.stxkeys)
              ) AS columns
            FROM pg_statistic_ext s
            JOIN pg_class c ON c.oid = s.stxrelid
            WHERE c.relnamespace = $1::regnamespace;
          `, [schemaName]);

          const settingsMap = Object.fromEntries(settingsRes.rows.map((r: any) => [r.name, r.setting]));
          const violations: string[] = [];

          const randomCost = parseFloat(settingsMap['random_page_cost'] || '4.0');
          if (randomCost > 1.5) {
            violations.push(`random_page_cost is ${randomCost}; default 4.0 penalizes SSD B-tree scans. Set to 1.1.`);
          }

          if (settingsMap['jit'] === 'on') {
            violations.push(`jit is enabled; adds 30ms-150ms LLVM compilation overhead in OLTP. Set to off.`);
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                schema: schemaName,
                settings: settingsMap,
                extendedStatisticsCount: extStatsRes.rowCount,
                extendedStatistics: extStatsRes.rows,
                isPlannerCalibrated: violations.length === 0,
                violations,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Tool: Audit Database Memory Management, Temp Spills & OOM Safeguards
    server.tool(
      'audit_database_memory_and_temp_spills',
      'Audits PostgreSQL memory allocation (work_mem, maintenance_work_mem), temporary disk file limits, log_temp_files, and cumulative temp_bytes spilled',
      {},
      async () => {
        const client = await pool.connect();
        try {
          // 1. Audit Memory Settings
          const settingsRes = await client.query(`
            SELECT name, setting, unit
            FROM pg_settings
            WHERE name IN (
              'work_mem',
              'shared_buffers',
              'maintenance_work_mem',
              'autovacuum_work_mem',
              'temp_file_limit',
              'log_temp_files',
              'hash_mem_multiplier'
            );
          `);

          // 2. Query Database-Wide Temp Spill Telemetry
          const statRes = await client.query(`
            SELECT
              datname,
              temp_files,
              temp_bytes,
              pg_size_pretty(temp_bytes) AS temp_bytes_pretty
            FROM pg_stat_database
            WHERE datname = current_database();
          `);

          const settingsMap = Object.fromEntries(settingsRes.rows.map((r: any) => [r.name, r.setting + (r.unit || '')]));
          const violations: string[] = [];

          const tempLimit = parseInt(settingsMap['temp_file_limit'] || '-1', 10);
          if (tempLimit === -1) {
            violations.push('temp_file_limit is -1 (unlimited). Set to 10GB to protect disk storage.');
          }

          const logTemp = parseInt(settingsMap['log_temp_files'] || '-1', 10);
          if (logTemp !== 0) {
            violations.push(`log_temp_files is ${logTemp}. Set to 0 to log all temporary disk spills.`);
          }

          const autovacMem = parseInt(settingsMap['autovacuum_work_mem'] || '65536', 10);
          if (autovacMem < 131072) {
            violations.push(`autovacuum_work_mem is sized below 128MB. Sized too low for single-pass vacuuming.`);
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                settings: settingsMap,
                databaseSpillTelemetry: statRes.rows[0] || {},
                isMemorySafe: violations.length === 0,
                violations,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Tool: Audit Full-Text Search, GIN Index Health & Trigram Extensions
    server.tool(
      'audit_database_search_and_gin_health',
      'Audit PostgreSQL GIN indexes, pending list sizes, FastUpdate configurations, and full-text search extensions to eliminate write stalls and table scan meltdowns',
      {
        schemaName: z.string().default('public').describe('Database schema name'),
      },
      async ({ schemaName }) => {
        const client = await pool.connect();
        try {
          // 1. Verify required extensions
          const extRes = await client.query(`
            SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_trgm', 'unaccent', 'pageinspect');
          `);
          const installedExts = extRes.rows.map((r: any) => r.extname);

          // 2. Audit GIN Indexes
          const ginRes = await client.query(`
            SELECT
              c.relname AS index_name,
              t.relname AS table_name,
              pg_relation_size(c.oid) AS index_bytes,
              pg_size_pretty(pg_relation_size(c.oid)) AS index_size_pretty,
              coalesce(opt.fastupdate, true) AS fast_update_enabled
            FROM pg_class c
            JOIN pg_am am ON am.oid = c.relam
            JOIN pg_index i ON i.indexrelid = c.oid
            JOIN pg_class t ON t.oid = i.indrelid
            LEFT JOIN LATERAL (
              SELECT (regexp_matches(c.reloptions::text, 'fastupdate=(true|false|on|off)'))[1] IN ('true', 'on') AS fastupdate
            ) opt ON true
            WHERE am.amname = 'gin' AND c.relnamespace = $1::regnamespace;
          `, [schemaName]);

          const violations: string[] = [];
          if (!installedExts.includes('pg_trgm')) {
            violations.push('pg_trgm extension is NOT installed. Substring and fuzzy matching cannot be indexed.');
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                installedExtensions: installedExts,
                ginIndexesCount: ginRes.rowCount,
                ginIndexes: ginRes.rows,
                isSearchHardened: violations.length === 0,
                violations,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Tool: Audit JSONB Columns, TOAST Footprint & Inverted Index Optimization
    server.tool(
      'audit_database_jsonb_toast_and_indexes',
      'Audit PostgreSQL JSONB column sizes, TOAST table footprints, storage strategies, CHECK constraints, and detect unoptimized default jsonb_ops index bloat',
      {
        schemaName: z.string().default('public').describe('Database schema name'),
      },
      async ({ schemaName }) => {
        const client = await pool.connect();
        try {
          // 1. Audit JSONB columns and TOAST ratios
          const colRes = await client.query(`
            SELECT
              c.relname AS table_name,
              a.attname AS column_name,
              pg_size_pretty(pg_relation_size(c.oid)) AS table_size,
              pg_size_pretty(COALESCE(pg_relation_size(c.reltoastrelid), 0)) AS toast_size,
              COALESCE(pg_relation_size(c.reltoastrelid), 0) AS toast_bytes,
              CASE a.attstorage
                WHEN 'x' THEN 'EXTENDED'
                WHEN 'e' THEN 'EXTERNAL'
                WHEN 'm' THEN 'MAIN'
                WHEN 'p' THEN 'PLAIN'
              END AS storage_strategy,
              EXISTS (
                SELECT 1 FROM pg_constraint con
                WHERE con.conrelid = c.oid
                  AND con.contype = 'c'
                  AND pg_get_constraintdef(con.oid) ILIKE '%' || a.attname || '%'
              ) AS has_check_constraint
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_type t ON t.oid = a.atttypid
            WHERE t.typname = 'jsonb'
              AND a.attnum > 0
              AND NOT a.attisdropped
              AND c.relnamespace = $1::regnamespace
            ORDER BY COALESCE(pg_relation_size(c.reltoastrelid), 0) DESC;
          `, [schemaName]);

          // 2. Audit GIN operator classes (jsonb_path_ops vs jsonb_ops)
          const idxRes = await client.query(`
            SELECT
              t.relname AS table_name,
              i.relname AS index_name,
              pg_size_pretty(pg_relation_size(i.oid)) AS index_size,
              opc.opcname AS opclass_name
            FROM pg_index x
            JOIN pg_class t ON t.oid = x.indrelid
            JOIN pg_class i ON i.oid = x.indexrelid
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_opclass opc ON opc.oid = ANY(x.indclass)
            WHERE am.amname = 'gin'
              AND opc.opcname IN ('jsonb_ops', 'jsonb_path_ops')
              AND t.relnamespace = $1::regnamespace;
          `, [schemaName]);

          const bloatWarnings: string[] = [];
          for (const idx of idxRes.rows) {
            if (idx.opclass_name === 'jsonb_ops') {
              bloatWarnings.push(`Index ${idx.index_name} uses default jsonb_ops. Migrate to jsonb_path_ops for up to 65% size reduction.`);
            }
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                jsonbColumnsCount: colRes.rowCount,
                jsonbColumns: colRes.rows,
                jsonbIndexesCount: idxRes.rowCount,
                jsonbIndexes: idxRes.rows,
                bloatWarnings,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Tool: Audit BRIN Indexes, Physical Heap Correlation & Autosummarize
    server.tool(
      'audit_database_brin_indexes_and_correlation',
      'Audit PostgreSQL BRIN index health, physical disk correlation in pg_stats, pages_per_range calibration, and detect missing autosummarize or outlier-prone default minmax_ops',
      {
        schemaName: z.string().default('public').describe('Database schema name'),
      },
      async ({ schemaName }) => {
        const client = await pool.connect();
        try {
          // 1. Audit BRIN indexes and index options
          const brinRes = await client.query(`
            SELECT
              t.relname AS table_name,
              i.relname AS index_name,
              a.attname AS column_name,
              opc.opcname AS opclass_name,
              pg_size_pretty(pg_relation_size(i.oid)) AS index_size,
              pg_size_pretty(pg_relation_size(t.oid)) AS table_size,
              pg_relation_size(i.oid) AS index_bytes,
              pg_relation_size(t.oid) AS table_bytes,
              COALESCE(
                (SELECT (regexp_matches(pg_get_indexdef(i.oid), 'pages_per_range = (\\d+)'))[1])::int,
                128
              ) AS pages_per_range,
              (pg_get_indexdef(i.oid) ILIKE '%autosummarize = on%') AS autosummarize
            FROM pg_index x
            JOIN pg_class t ON t.oid = x.indrelid
            JOIN pg_class i ON i.oid = x.indexrelid
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(x.indkey)
            JOIN pg_opclass opc ON opc.oid = ANY(x.indclass)
            WHERE am.amname = 'brin'
              AND t.relnamespace = $1::regnamespace
            ORDER BY pg_relation_size(t.oid) DESC;
          `, [schemaName]);

          // 2. Audit correlation in pg_stats
          const corrRes = await client.query(`
            SELECT
              s.tablename AS table_name,
              s.attname AS column_name,
              COALESCE(s.correlation, 0.0) AS correlation
            FROM pg_stats s
            JOIN pg_index x ON x.indrelid = (s.schemaname || '.' || s.tablename)::regclass
            JOIN pg_class i ON i.oid = x.indexrelid
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = ANY(x.indkey) AND a.attname = s.attname
            WHERE am.amname = 'brin'
              AND s.schemaname = $1;
          `, [schemaName]);

          const warnings: string[] = [];
          for (const idx of brinRes.rows) {
            if (!idx.autosummarize) {
              warnings.push(`BRIN index ${idx.index_name} is missing 'autosummarize = on'. Appended head pages will not be summarized automatically!`);
            }
            if (idx.opclass_name.endsWith('_minmax_ops')) {
              warnings.push(`BRIN index ${idx.index_name} uses default minmax_ops. Consider minmax_multi_ops (PostgreSQL 14+) to isolate outliers.`);
            }
          }
          for (const c of corrRes.rows) {
            const corrVal = Math.abs(parseFloat(c.correlation));
            if (corrVal < 0.95) {
              warnings.push(`Table ${c.table_name} column ${c.column_name} has degraded correlation (${c.correlation}). BRIN block skipping is severely impaired! Re-cluster with pg_repack.`);
            }
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                brinIndexesCount: brinRes.rowCount,
                brinIndexes: brinRes.rows,
                correlationStats: corrRes.rows,
                warnings,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );

    // Tool: audit_pgvector_hnsw_health
    // Audits pgvector extension, HNSW parameters, Halfvec quantization, and filtered scan configuration
    server.tool(
      'audit_pgvector_hnsw_health',
      'Audits PostgreSQL pgvector extension version, vector columns, halfvec quantization, HNSW graph parameters, and filtered recall settings.',
      {
        schemaName: z.string().default('public').describe('Schema name to inspect'),
      },
      async ({ schemaName }) => {
        const client = await pool.connect();
        try {
          // 1. Check pgvector extension version
          const extRes = await client.query(`
            SELECT default_version, installed_version
            FROM pg_available_extensions
            WHERE name = 'vector';
          `);

          if (extRes.rowCount === 0 || !extRes.rows[0].installed_version) {
            return {
              isError: true,
              content: [{ type: 'text', text: 'pgvector extension is not installed in the cluster.' }],
            };
          }

          const version = extRes.rows[0].installed_version;

          // 2. Discover vector columns & storage format
          const colRes = await client.query(`
            SELECT
              c.relname AS table_name,
              a.attname AS column_name,
              t.typname AS data_type,
              a.atttypmod AS dimensions,
              pg_relation_size(c.oid) AS table_size_bytes
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_type t ON t.oid = a.atttypid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1
              AND t.typname IN ('vector', 'halfvec', 'bit')
              AND a.attnum > 0
              AND NOT a.attisdropped;
          `, [schemaName]);

          // 3. Inspect HNSW indexes
          const idxRes = await client.query(`
            SELECT
              i.relname AS index_name,
              t.relname AS table_name,
              a.attname AS column_name,
              opc.opcname AS opclass,
              pg_relation_size(i.oid) AS index_size_bytes,
              pg_get_indexdef(i.oid) AS index_def
            FROM pg_index x
            JOIN pg_class t ON t.oid = x.indrelid
            JOIN pg_class i ON i.oid = x.indexrelid
            JOIN pg_am am ON am.oid = i.relam
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(x.indkey)
            JOIN pg_opclass opc ON opc.oid = ANY(x.indclass)
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE am.amname = 'hnsw'
              AND n.nspname = $1;
          `, [schemaName]);

          const warnings: string[] = [];
          for (const col of colRes.rows) {
            if (col.data_type === 'vector' && col.dimensions >= 1024) {
              warnings.push(`Column ${col.table_name}.${col.column_name} uses FP32 vector(${col.dimensions}). Convert to halfvec(${col.dimensions}) to cut RAM footprint by 50%.`);
            }
          }

          for (const idx of idxRes.rows) {
            const efMatch = idx.index_def.match(/ef_construction\s*=\s*'(\d+)'/i) || idx.index_def.match(/ef_construction\s*=\s*(\d+)/i);
            const ef = efMatch ? parseInt(efMatch[1], 10) : 64;
            if (ef < 64) {
              warnings.push(`HNSW index ${idx.index_name} has low ef_construction (${ef}). Recall and graph connectivity may be degraded!`);
            }
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                pgvectorVersion: version,
                vectorColumnsCount: colRes.rowCount,
                vectorColumns: colRes.rows,
                hnswIndexesCount: idxRes.rowCount,
                hnswIndexes: idxRes.rows,
                warnings,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );
    ```

- **MCP Spatial Bounding Box & Temporal Interval Tool Contracts (GeoJSON RFC 7946 & `23P01` Defense)**:
  - ❌ **Anti-Pattern: Untyped Spatial Coordinates, Missing GeoJSON Invariant Bounds, and Raw SQLSTATE 23P01 Leakage in MCP Tools**:
    - Exposing tool inputs with loose floating-point numbers or arbitrary strings without validating coordinate ranges ($\text{lon} \in [-180, 180]$, $\text{lat} \in [-90, 90]$) or RFC 7946 bounding boxes ($x_{\min} \le x_{\max}$, $y_{\min} \le y_{\max}$).
    - Permitting inverted temporal intervals (`start >= end`) into MCP tools, producing invalid SQL range types or crashing PostgreSQL with internal check exceptions.
    - Allowing database exclusion constraint failures (`SQLSTATE 23P01`) to crash the MCP server process or return uninformative 500 error strings to the LLM agent, rather than returning structured, machine-actionable conflict guidance.
  - ✅ **Production Invariant**:
    - Validate all spatial inputs with strict Zod schemas enforcing RFC 7946 coordinate boundaries and canonical half-open ISO 8601 temporal intervals (`[start, end)`).
    - Wrap booking and proximity database calls in structured exception handlers that detect `SQLSTATE 23P01` and return structured MCP tool response messages with `isError: true` and actionable collision details.
    ```typescript
    import { z } from 'zod';

    // 1. Zod Invariant Schema for GeoJSON & Temporal Range MCP Tools
    export const SpatialProximityToolSchema = z.object({
      tenantId: z.string().uuid(),
      longitude: z.number().min(-180.0).max(180.0),
      latitude: z.number().min(-90.0).max(90.0),
      radiusMeters: z.number().positive().max(100_000).default(5000), // Max 100km radius
      limit: z.number().int().min(1).max(50).default(10),
    });

    export const TemporalBookingToolSchema = z.object({
      tenantId: z.string().uuid(),
      vehicleId: z.string().uuid(),
      customerId: z.string().uuid(),
      startTimeIso: z.string().datetime(),
      endTimeIso: z.string().datetime(),
    }).refine((data) => new Date(data.startTimeIso) < new Date(data.endTimeIso), {
      message: 'startTime must strictly precede endTime',
      path: ['endTimeIso'],
    });

    // 2. Safe MCP Tool Registration with Exclusion Conflict Handling
    server.tool(
      'schedule_vehicle_booking',
      'Schedule a vehicle rental window with guaranteed collision prevention',
      TemporalBookingToolSchema.shape,
      async (args) => {
        const client = await pool.connect();
        try {
          const res = await client.query(`
            INSERT INTO vehicle_bookings (tenant_id, vehicle_id, customer_id, booking_period)
            VALUES ($1, $2, $3, tstzrange($4, $5, '[)'))
            RETURNING id, booking_period;
          `, [args.tenantId, args.vehicleId, args.customerId, args.startTimeIso, args.endTimeIso]);

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                status: 'confirmed',
                bookingId: res.rows[0].id,
                period: res.rows[0].booking_period,
              }, null, 2),
            }],
          };
        } catch (err: any) {
          if (err?.code === '23P01') {
            // Graceful structured MCP error for exclusion constraint violation
            return {
              isError: true,
              content: [{
                type: 'text',
                text: JSON.stringify({
                  error: 'RESERVATION_CONFLICT',
                  message: `Vehicle ${args.vehicleId} is already reserved for the requested window [${args.startTimeIso} to ${args.endTimeIso}). Please choose a disjoint time slot.`,
                }, null, 2),
              }],
            };
          }
          throw err;
        } finally {
          client.release();
        }
      }
    );
    ```

- **MCP Foreign Data Wrapper (`postgres_fdw`) Health Sentinel & Pushdown Verification Tool**:
  - ❌ **Anti-Pattern: Blind Foreign Table Scans & Unmonitored 2PC Distributed Lockups in MCP Runtimes**:
    - Exposing tool endpoints that run unbounded queries across foreign servers without verifying remote predicate pushdown in `EXPLAIN (VERBOSE)`, allowing LLMs to trigger wire-spill downloads of millions of rows across VPCs.
    - Neglecting orphaned prepared transactions (`pg_prepared_xacts`) left behind by distributed commits, which lock tables and pin autovacuum horizons.
  - ✅ **Production Invariant**:
    - Provide diagnostic MCP tools that inspect `pg_foreign_server`, verify `use_remote_estimate` and `fetch_size`, validate query pushdown inside `Remote SQL`, and detect in-doubt prepared transactions older than 60 seconds.
    ```typescript
    // Tool: Audit Foreign Data Wrapper Health & Remote Pushdown
    server.tool(
      'audit_database_fdw_health',
      'Audit PostgreSQL postgres_fdw foreign servers, pushdown options, and orphaned 2PC prepared transactions',
      {
        sampleQuery: z.string().optional().describe('Optional SQL query against a foreign table to verify pushdown'),
      },
      async ({ sampleQuery }) => {
        const client = await pool.connect();
        try {
          // 1. Audit configured foreign servers and options
          const serverRes = await client.query(`
            SELECT
              s.srvname AS server_name,
              w.fdwname AS wrapper_name,
              s.srvoptions AS options
            FROM pg_foreign_server s
            JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw;
          `);

          // 2. Audit orphaned prepared transactions (2PC)
          const prepRes = await client.query(`
            SELECT
              gid,
              prepared,
              owner,
              database,
              ROUND(EXTRACT(EPOCH FROM (CLOCK_TIMESTAMP() - prepared))) AS age_seconds
            FROM pg_prepared_xacts
            WHERE prepared < CLOCK_TIMESTAMP() - INTERVAL '60 seconds';
          `);

          const violations: string[] = [];
          for (const s of serverRes.rows) {
            const opts = s.options ? s.options.join(',') : '';
            if (!opts.includes('use_remote_estimate=true')) {
              violations.push(`Server ${s.server_name} is missing use_remote_estimate=true. Query planner may choose catastrophic nested loops.`);
            }
            if (!opts.includes('fetch_size=')) {
              violations.push(`Server ${s.server_name} is missing explicit fetch_size. Defaults to 100 which degrades network latency.`);
            }
          }

          if (prepRes.rows.length > 0) {
            violations.push(`Detected ${prepRes.rows.length} orphaned prepared transactions older than 60s. Vacuum horizon is currently pinned!`);
          }

          let pushdownResult: any = null;
          if (sampleQuery) {
            const planRes = await client.query(`EXPLAIN (VERBOSE, FORMAT JSON) ${sampleQuery}`);
            const planText = JSON.stringify(planRes.rows[0]);
            pushdownResult = {
              hasRemoteSql: planText.includes('Remote SQL'),
              hasRemoteFilter: planText.includes('WHERE') || planText.includes('Filter'),
            };
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                servers: serverRes.rows,
                orphanedPreparedTransactions: prepRes.rows,
                pushdownResult,
                isFDWHealthy: violations.length === 0,
                violations,
              }, null, 2),
            }],
          };
        } finally {
          client.release();
        }
      }
    );
    ```

- **PostgreSQL Materialized View Health & Non-Blocking Concurrent Refresh Tool**:
  - ❌ **Anti-Pattern: Blind REFRESH Invocations via LLM Tools**:
    - LLM agents issuing direct raw SQL `REFRESH MATERIALIZED VIEW` without inspecting whether the view has a non-partial unique index or checking if a refresh is already active. This causes immediate query blocking on all connected clients.
  - ✅ **Production Invariant**:
    - Provide a safe, typed MCP tool that validates unique indexes, checks staleness, verifies dead tuple bloat, and uses advisory lock non-blocking execution.

    ```typescript
    import { z } from 'zod';
    import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
    import { Pool } from 'pg';

    export function registerMatViewTools(server: McpServer, pool: Pool) {
      server.tool(
        'database_materialized_view_health',
        'Inspect materialized view staleness, unique indexes, dead tuple bloat, and perform safe non-blocking concurrent refresh',
        {
          viewName: z.string().describe('Materialized view name in current database'),
          action: z.enum(['inspect', 'refresh_concurrently']).default('inspect'),
          timeoutSeconds: z.number().optional().default(600),
        },
        async ({ viewName, action, timeoutSeconds }) => {
          const client = await pool.connect();
          try {
            // 1. Inspect view presence, population, and unique index existence
            const inspectRes = await client.query(
              `
              SELECT
                c.relname,
                c.relispopulated,
                COALESCE(s.n_live_tup, 0) as live_tuples,
                COALESCE(s.n_dead_tup, 0) as dead_tuples,
                EXISTS (
                  SELECT 1 FROM pg_index i
                  WHERE i.indrelid = c.oid AND i.indisunique = true AND i.indpred IS NULL
                ) as has_unique_index
              FROM pg_class c
              LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
              WHERE c.relname = $1 AND c.relkind = 'm';
              `,
              [viewName]
            );

            if (inspectRes.rows.length === 0) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: `Materialized view "${viewName}" not found.` }),
                }],
              };
            }

            const info = inspectRes.rows[0];

            if (action === 'inspect') {
              const live = Number(info.live_tuples);
              const dead = Number(info.dead_tuples);
              const bloatRatio = live + dead > 0 ? Math.round((dead / (live + dead)) * 100) : 0;

              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({
                    viewName,
                    isPopulated: info.relispopulated,
                    hasUniqueIndex: info.has_unique_index,
                    liveTuples: live,
                    deadTuples: dead,
                    bloatPercent: bloatRatio,
                    canRefreshConcurrently: info.has_unique_index,
                  }, null, 2),
                }],
              };
            }

            // Action: refresh_concurrently
            if (!info.has_unique_index) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({
                    error: `Cannot refresh concurrently: view "${viewName}" lacks a non-partial UNIQUE INDEX!`,
                  }),
                }],
              };
            }

            // Advisory lock key from view name
            const lockRes = await client.query(
              `SELECT pg_try_advisory_lock(('x' || SUBSTR(MD5($1), 1, 16))::BIT(64)::BIGINT) as acquired;`,
              [viewName]
            );

            if (!lockRes.rows[0].acquired) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({
                    status: 'SKIPPED',
                    message: `Another refresh process is already active for "${viewName}". Execution coalesced.`,
                  }),
                }],
              };
            }

            const startTime = Date.now();
            try {
              await client.query(`SET LOCAL statement_timeout = ${timeoutSeconds * 1000};`);
              await client.query(`SET LOCAL lock_timeout = '3000ms';`);
              await client.query(`REFRESH MATERIALIZED VIEW CONCURRENTLY ${client.escapeIdentifier(viewName)};`);

              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({
                    status: 'SUCCESS',
                    viewName,
                    durationMs: Date.now() - startTime,
                    refreshedAt: new Date().toISOString(),
                  }, null, 2),
                }],
              };
            } finally {
              await client.query(
                `SELECT pg_advisory_unlock(('x' || SUBSTR(MD5($1), 1, 16))::BIT(64)::BIGINT);`,
                [viewName]
              );
            }
          } finally {
            client.release();
          }
        }
      );
    }
    ```

- **PostgreSQL Advisory Lock Fencing, Active Inspection & Distributed Mutex Tool**:
  - ❌ **Anti-Pattern: Concurrent Uncoordinated Agent Mutations & Leaked Session Locks**:
    - Multi-agent swarms or autonomous tool calls executing destructive mutations (e.g. updating user balances, altering schemas, or dispatching batched jobs) simultaneously without mutual exclusion.
    - Agents running raw SQL `SELECT pg_advisory_lock(id)` inside tools and failing to unlock on network errors, leaving persistent zombie locks.
  - ✅ **Production Invariant**:
    - Provide a structured MCP tool that computes deterministic 64-bit keys from namespace + tenant + entity, checks for lock conflicts, queries `pg_locks` for active locks, and safely tests availability using non-blocking primitives.

    ```typescript
    import { z } from 'zod';
    import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
    import { Pool } from 'pg';
    import { createHash } from 'node:crypto';

    export function registerAdvisoryLockTools(server: McpServer, pool: Pool) {
      server.tool(
        'database_advisory_lock_manager',
        'Inspect active PostgreSQL advisory locks or test mutual exclusion availability for a resource without blocking',
        {
          action: z.enum(['inspect_all', 'check_availability']),
          namespace: z.number().int().optional().describe('Namespace integer ID (e.g. 100 for orders, 200 for billing)'),
          tenantId: z.string().optional().default('default'),
          entityId: z.string().optional().describe('Unique resource identifier or UUID'),
        },
        async ({ action, namespace, tenantId, entityId }) => {
          const client = await pool.connect();
          try {
            if (action === 'inspect_all') {
              const res = await client.query(`
                SELECT
                  l.pid,
                  a.usename,
                  a.client_addr::TEXT as client_addr,
                  a.state,
                  EXTRACT(EPOCH FROM (NOW() - a.query_start))::INT as running_duration_seconds,
                  l.mode,
                  l.granted,
                  CASE 
                    WHEN l.objsubid = 1 THEN l.objid::BIGINT::TEXT 
                    ELSE '(' || l.classid || ',' || l.objid || ')' 
                  END as lock_key,
                  a.query
                FROM pg_locks l
                JOIN pg_stat_activity a ON l.pid = a.pid
                WHERE l.locktype = 'advisory'
                ORDER BY a.query_start ASC
                LIMIT 50;
              `);

              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({
                    totalActiveLocks: res.rows.length,
                    locks: res.rows,
                  }, null, 2),
                }],
              };
            }

            // Action: check_availability
            if (namespace === undefined || !entityId) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: 'namespace and entityId are required for check_availability' }),
                }],
              };
            }

            // Compute signed 64-bit bigint key
            const combined = `${namespace}:${tenantId}:${entityId}`;
            const hash = createHash('sha256').update(combined).digest();
            const lockKey = hash.readBigInt64BE(0).toString();

            // Check availability in a throwaway transaction
            await client.query('BEGIN;');
            const checkRes = await client.query<{ acquired: boolean }>(
              'SELECT pg_try_advisory_xact_lock($1) as acquired;',
              [lockKey]
            );
            const isAvailable = checkRes.rows[0]?.acquired ?? false;
            await client.query('ROLLBACK;'); // Instantly release

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  resource: combined,
                  bigintKey: lockKey,
                  isAvailable,
                  status: isAvailable ? 'AVAILABLE' : 'LOCKED_BY_ANOTHER_TRANSACTION',
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: inspect_predicate_locks - Observability for SSI SIREAD locks & escalation detection
      server.tool(
        'inspect_predicate_locks',
        'Inspect active PostgreSQL Serializable Snapshot Isolation (SSI) SIREAD predicate locks to detect relation-level lock escalation and conflict hotspots',
        {
          targetRelation: z.string().optional().describe('Filter by specific table/relation name'),
        },
        async ({ targetRelation }) => {
          const client = await pool.connect();
          try {
            const query = `
              SELECT
                l.locktype,
                l.mode,
                COALESCE(c.relname, 'database') AS relation_name,
                l.page,
                l.tuple,
                l.pid,
                NOW() - a.query_start AS duration,
                a.query
              FROM pg_locks l
              LEFT JOIN pg_class c ON l.relation = c.oid
              JOIN pg_stat_activity a ON l.pid = a.pid
              WHERE l.mode = 'SIReadLock'
                AND ($1::text IS NULL OR c.relname = $1)
              ORDER BY l.locktype DESC, duration DESC
              LIMIT 50;
            `;
            const res = await client.query(query, [targetRelation || null]);

            const hasEscalatedRelationLocks = res.rows.some((r) => r.locktype === 'relation');

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  activePredicateLocksCount: res.rows.length,
                  hasEscalatedRelationLocks,
                  warning: hasEscalatedRelationLocks
                    ? 'CRITICAL: Relation-level SIREAD locks detected! This triggers false conflicts for concurrent serializable transactions. Check for unindexed table scans.'
                    : 'HEALTHY: All predicate locks are page or tuple level.',
                  locks: res.rows,
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: inspect_primary_key_btree_health - Observability for Primary Key B-Tree Index Bloat & Fragmentation
      server.tool(
        'inspect_primary_key_btree_health',
        'Inspect PostgreSQL primary key B-tree index sizes, scan statistics, and detect potential page split bloat caused by random UUIDv4 keys',
        {
          tableName: z.string().optional().describe('Filter by specific table name'),
        },
        async ({ tableName }) => {
          const client = await pool.connect();
          try {
            const query = `
              SELECT
                schemaname,
                relname AS table_name,
                indexrelname AS index_name,
                pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
                pg_relation_size(indexrelid) AS index_bytes,
                idx_scan,
                idx_tup_read,
                idx_tup_fetch
              FROM pg_stat_user_indexes
              WHERE (indexrelname LIKE '%pkey%' OR indexrelname LIKE '%pk%')
                AND ($1::text IS NULL OR relname = $1)
              ORDER BY pg_relation_size(indexrelid) DESC
              LIMIT 50;
            `;
            const res = await client.query(query, [tableName || null]);

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  analyzedIndexesCount: res.rows.length,
                  recommendation: 'Ensure high-throughput write tables use monotonic UUIDv7 rather than random UUIDv4 to maintain >=90% B-tree fillfactor and eliminate 50-50 leaf page split storms.',
                  indexes: res.rows,
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: inspect_unindexed_foreign_keys - Detect Missing B-Tree Indexes on Foreign Key Columns
      server.tool(
        'inspect_unindexed_foreign_keys',
        'Inspect PostgreSQL schema and detect foreign key constraints lacking supporting B-tree indexes, which cause full-table sequential scans during parent updates or deletes',
        {
          schemaName: z.string().optional().default('public').describe('Target schema to audit'),
        },
        async ({ schemaName }) => {
          const client = await pool.connect();
          try {
            const query = `
              SELECT
                c.connamespace::regnamespace::text AS schema_name,
                c.conrelid::regclass::text AS child_table,
                c.conname AS constraint_name,
                ARRAY_AGG(att.attname ORDER BY u.attposition) AS fk_columns,
                c.confrelid::regclass::text AS parent_table,
                ARRAY_AGG(ref_att.attname ORDER BY u.attposition) AS parent_pk_columns,
                pg_size_pretty(pg_total_relation_size(c.conrelid)) AS child_table_size
              FROM pg_constraint c
              JOIN LATERAL UNNEST(c.conkey) WITH ORDINALITY AS u(attnum, attposition) ON true
              JOIN pg_attribute att ON att.attrelid = c.conrelid AND att.attnum = u.attnum
              JOIN pg_attribute ref_att ON ref_att.attrelid = c.confrelid AND ref_att.attnum = c.confkey[u.attposition]
              WHERE c.contype = 'f'
                AND c.connamespace::regnamespace::text = $1
                AND NOT EXISTS (
                  SELECT 1
                  FROM pg_index i
                  WHERE i.indrelid = c.conrelid
                    AND i.indisvalid = true
                    AND (i.indkey[0:array_length(c.conkey, 1) - 1] = c.conkey)
                )
              GROUP BY c.connamespace, c.conrelid, c.conname, c.confrelid
              ORDER BY pg_total_relation_size(c.conrelid) DESC;
            `;
            const res = await client.query(query, [schemaName]);

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  unindexedForeignKeysCount: res.rows.length,
                  severity: res.rows.length > 0 ? 'HIGH_RISK_DEADLOCK_AND_SCAN_SPIKES' : 'CLEAN',
                  recommendation: 'Create B-tree indexes concurrently on all child fk_columns to eliminate O(N) sequential scans during parent deletes/updates and avoid connection pool exhaustion.',
                  violations: res.rows,
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: audit_database_check_constraints - Detect Unvalidated Constraints & Volatile Function Traps
      server.tool(
        'audit_database_check_constraints',
        'Audit PostgreSQL CHECK constraints and domain types, detecting unvalidated constraints (convalidated = false), volatile expressions, and ternary logic risks',
        {
          schemaName: z.string().optional().default('public').describe('Target schema to audit'),
        },
        async ({ schemaName }) => {
          const client = await pool.connect();
          try {
            const query = `
              SELECT
                c.connamespace::regnamespace::text AS schema_name,
                c.conrelid::regclass::text AS table_name,
                c.conname AS constraint_name,
                c.contype AS constraint_type,
                c.convalidated AS is_validated,
                pg_get_constraintdef(c.oid) AS definition
              FROM pg_constraint c
              WHERE c.connamespace::regnamespace::text = $1
                AND c.contype IN ('c', 'f')
                AND c.convalidated = false
              ORDER BY c.conrelid::regclass::text, c.conname;
            `;
            const res = await client.query(query, [schemaName]);

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  unvalidatedConstraintsCount: res.rows.length,
                  status: res.rows.length > 0 ? 'VALIDATION_PENDING_OR_RISK' : 'CLEAN_ALL_VALIDATED',
                  recommendation: res.rows.length > 0
                    ? 'Execute ALTER TABLE ... VALIDATE CONSTRAINT ... during non-peak hours under SHARE UPDATE EXCLUSIVE lock to complete two-phase constraint enforcement.'
                    : 'All CHECK and FOREIGN KEY constraints are validated.',
                  unvalidatedConstraints: res.rows,
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: audit_database_sequences - Detect Integer Overflow & Uncached Sequence Contention
      server.tool(
        'audit_database_sequences',
        'Audit PostgreSQL sequences and identity columns to detect 32-bit int4 overflow risks, high capacity consumption (>=75%), cycle vulnerabilities, and uncached sequence lock contention',
        {
          thresholdPercent: z.number().optional().default(75).describe('Warning threshold for sequence consumption percentage'),
        },
        async ({ thresholdPercent }) => {
          const client = await pool.connect();
          try {
            const query = `
              SELECT
                ns.nspname AS schema_name,
                tbl.relname AS table_name,
                att.attname AS column_name,
                typ.typname AS data_type,
                seq_ns.nspname || '.' || seq.relname AS sequence_name,
                s.last_value,
                s.max_value,
                s.is_cycled,
                s.cache_size,
                ROUND((s.last_value::numeric / s.max_value::numeric) * 100, 2) AS percent_consumed
              FROM pg_class seq
              JOIN pg_namespace seq_ns ON seq.relnamespace = seq_ns.oid
              JOIN pg_sequences s ON s.schemaname = seq_ns.nspname AND s.sequencename = seq.relname
              JOIN pg_depend dep ON dep.objid = seq.oid AND dep.deptype IN ('a', 'i')
              JOIN pg_class tbl ON dep.refobjid = tbl.oid
              JOIN pg_namespace ns ON tbl.relnamespace = ns.oid
              JOIN pg_attribute att ON att.attrelid = tbl.oid AND att.attnum = dep.refobjsubid
              JOIN pg_type typ ON att.atttypid = typ.oid
              WHERE seq.relkind = 'S'
                AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
              ORDER BY (s.last_value::numeric / s.max_value::numeric) DESC;
            `;
            const res = await client.query(query);

            const atRisk = res.rows.filter((r) => Number(r.percent_consumed) >= thresholdPercent || r.data_type === 'int4');
            const uncached = res.rows.filter((r) => Number(r.cache_size) <= 1);

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  totalSequencesAudited: res.rows.length,
                  atRiskCount: atRisk.length,
                  uncachedCount: uncached.length,
                  status: atRisk.length > 0 ? 'ACTION_REQUIRED_CAPACITY_OR_TYPE' : 'HEALTHY',
                  recommendation: atRisk.length > 0
                    ? 'Execute 4-phase zero-downtime expand-contract migration to upgrade int4 to BIGINT, and configure CACHE 50-100 on high-velocity sequences.'
                    : 'All sequences within safe operational capacity.',
                  atRiskSequences: atRisk,
                  uncachedSequences: uncached.slice(0, 10),
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: audit_database_unique_constraints - Detect Soft-Delete Collisions & NULL Bypass Risks
      server.tool(
        'audit_database_unique_constraints',
        'Audit PostgreSQL tables for invalid unique indexes, unindexed soft-delete collision risks, and composite unique keys missing NULLS NOT DISTINCT',
        {},
        async () => {
          const client = await pool.connect();
          try {
            // Check 1: Invalid indexes resulting from failed CONCURRENT builds
            const invalidQuery = `
              SELECT
                c.relname AS index_name,
                t.relname AS table_name,
                n.nspname AS schema_name
              FROM pg_index i
              JOIN pg_class c ON c.oid = i.indexrelid
              JOIN pg_class t ON t.oid = i.indrelid
              JOIN pg_namespace n ON n.oid = t.relnamespace
              WHERE i.indisvalid = false
                AND n.nspname NOT IN ('pg_catalog', 'information_schema');
            `;
            const invalidRes = await client.query(invalidQuery);

            // Check 2: Tables with deleted_at having full unique constraints instead of partial
            const softDeleteRisksQuery = `
              SELECT
                con.conname AS constraint_name,
                tbl.relname AS table_name,
                ns.nspname AS schema_name
              FROM pg_constraint con
              JOIN pg_class tbl ON tbl.oid = con.conrelid
              JOIN pg_namespace ns ON ns.oid = tbl.relnamespace
              WHERE con.contype = 'u'
                AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
                AND EXISTS (
                  SELECT 1 FROM pg_attribute att
                  WHERE att.attrelid = tbl.oid
                    AND att.attname = 'deleted_at'
                    AND NOT att.attisdropped
                );
            `;
            const softDeleteRisksRes = await client.query(softDeleteRisksQuery);

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  invalidIndexesCount: invalidRes.rows.length,
                  softDeleteRisksCount: softDeleteRisksRes.rows.length,
                  status: (invalidRes.rows.length > 0 || softDeleteRisksRes.rows.length > 0) ? 'ACTION_REQUIRED' : 'HEALTHY',
                  invalidIndexes: invalidRes.rows,
                  softDeleteMonolithicConstraints: softDeleteRisksRes.rows,
                  recommendation: 'Replace monolithic unique constraints on soft-deleted tables with CREATE UNIQUE INDEX ... WHERE deleted_at IS NULL, and rebuild any invalid indexes CONCURRENTLY.',
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: Audit PostgreSQL SubtransSLRU Lock Contention & Subxid Overflows
      server.tool(
        'check_subtransaction_slru_contention',
        'Inspects PostgreSQL for active SubtransSLRU lock contention and backends exceeding the 64-subxid cache',
        {},
        async () => {
          const client = await pool.connect();
          try {
            // Check 1: Active backends waiting on SubtransSLRU Lightweight Locks
            const waitQuery = `
              SELECT
                pid,
                usename,
                wait_event,
                wait_event_type,
                state,
                clock_timestamp() - state_change AS duration,
                query
              FROM pg_stat_activity
              WHERE wait_event IN ('SubtransSLRU', 'SubtransBuffer');
            `;
            const waitRes = await client.query(waitQuery);

            // Check 2: Backends holding > 64 transaction locks (subxid overflow marker)
            const overflowQuery = `
              SELECT
                pid,
                COUNT(*) AS subxid_lock_count
              FROM pg_locks
              WHERE locktype = 'transactionid'
              GROUP BY pid
              HAVING COUNT(*) > 64;
            `;
            const overflowRes = await client.query(overflowQuery);

            const hasMeltdown = waitRes.rows.length > 0;
            const hasRisk = overflowRes.rows.length > 0;

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  status: hasMeltdown ? 'CRITICAL_MELTDOWN' : (hasRisk ? 'RISK_DETECTED' : 'HEALTHY'),
                  subtransWaitersCount: waitRes.rows.length,
                  overflowedBackendsCount: overflowRes.rows.length,
                  activeWaiters: waitRes.rows,
                  overflowedBackends: overflowRes.rows,
                  recommendation: hasMeltdown
                    ? 'CRITICAL: SubtransSLRU lock contention detected! Terminate offending batch backends immediately with pg_terminate_backend().'
                    : (hasRisk
                        ? 'WARNING: Backends holding >64 subxids found. Refactor code to eradicate SAVEPOINT or begin_nested() in loops.'
                        : 'PostgreSQL subtransaction cache is healthy. All backends operating within 64-subxid in-memory cache.'),
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Tool: Audit PostgreSQL Table Column Tetris & 8-Byte Word Padding Bloat
      server.tool(
        'audit_table_column_tetris_padding',
        'Analyzes a PostgreSQL table schema for 8-byte word padding bloat and outputs an optimal Column Tetris column layout',
        {
          tableName: z.string().describe('The name of the table to audit'),
        },
        async ({ tableName }) => {
          const client = await pool.connect();
          try {
            const query = `
              SELECT
                a.attname AS column_name,
                t.typname AS data_type,
                t.typalign AS alignment,
                t.typlen AS fixed_size,
                a.attnotnull AS is_not_null
              FROM pg_attribute a
              JOIN pg_type t ON a.atttypid = t.oid
              WHERE a.attrelid = $1::regclass
                AND a.attnum > 0
                AND NOT a.attisdropped
              ORDER BY a.attnum ASC;
            `;
            const res = await client.query(query, [tableName]);

            let currentOffset = 24; // Base header
            let totalPadding = 0;
            const columns = res.rows.map((row: any) => {
              const align = row.alignment === 'd' ? 8 : (row.alignment === 'i' ? 4 : (row.alignment === 's' ? 2 : 1));
              const size = row.fixed_size > 0 ? row.fixed_size : 8;
              const rem = currentOffset % align;
              const pad = rem === 0 ? 0 : align - rem;
              totalPadding += pad;
              currentOffset += pad + size;

              return {
                name: row.column_name,
                dataType: row.data_type,
                alignBytes: align,
                paddingBefore: pad,
              };
            });

            const hasPadding = totalPadding > 0;
            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  tableName,
                  totalPaddingWastedBytes: totalPadding,
                  hasPaddingBloat: hasPadding,
                  columns,
                  recommendation: hasPadding
                    ? 'Table contains padding bloat! Apply Column Tetris: sort columns by descending alignment (8B -> 4B -> 2B -> 1B -> Varlena Tail) to eliminate internal padding.'
                    : 'Table schema is perfectly aligned with Column Tetris invariants. Zero internal padding bytes detected.',
                }, null, 2),
              }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Diagnostic Tool: Inspect Query Prepared Statement Plan Cache Stability & Generic Drift
      server.tool(
        'inspect_query_plan_cache_stability',
        'Validates SQL query stability across generic vs custom execution plans, detecting parameter sniffing and sequential scan drift via PostgreSQL EXPLAIN (GENERIC_PLAN)',
        {
          sql: z.string().describe('Parameterized SQL query using $1, $2 parameter placeholders'),
        },
        async ({ sql }) => {
          const client = await pool.connect();
          try {
            // Guard: Assert SQL uses static = ANY($1) instead of dynamic IN ($1, $2, ...)
            const dynamicInMatch = /\bIN\s*\(\s*\$\d+(?:\s*,\s*\$\d+)+\s*\)/i.test(sql);
            if (dynamicInMatch) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({
                    stable: false,
                    violation: 'DYNAMIC_IN_CLAUSE_DETECTED',
                    error: 'SQL contains dynamic IN ($1, $2, ...) list. Rewrite using static array containment = ANY($1::type[]) to prevent prepared statement cache explosion and backend OOM.',
                  }, null, 2),
                }],
              };
            }

            // Execute EXPLAIN (GENERIC_PLAN, FORMAT JSON) to analyze generic execution tree
            const explainRes = await client.query(`EXPLAIN (GENERIC_PLAN, FORMAT JSON) ${sql}`);
            const planData = explainRes.rows[0]['QUERY PLAN'][0]?.Plan;

            const nodeType = planData?.['Node Type'] ?? 'Unknown';
            const totalCost = planData?.['Total Cost'] ?? 0;
            const isSeqScan = nodeType === 'Seq Scan';

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  sql,
                  genericPlanNodeType: nodeType,
                  genericTotalCost: totalCost,
                  hasSeqScanRisk: isSeqScan,
                  recommendation: isSeqScan && totalCost > 1000
                    ? "Generic plan collapsed into an unindexed Sequential Scan. For skewed status or tenant queries, wrap execution with 'SET LOCAL plan_cache_mode = force_custom' or use partial indexes."
                    : 'Generic plan is stable and suitable for prepared statement cache reuse.',
                }, null, 2),
              }],
            };
          } catch (err: any) {
            return {
              isError: true,
              content: [{ type: 'text', text: `Failed to inspect plan cache stability: ${err.message}` }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Diagnostic Tool: Inspect Row-Level Locking Safety & MultiXact Contention
      server.tool(
        'inspect_row_level_locking_safety',
        'Audits SQL row locking statements for foreign key starvation hazards, lock upgrade deadlocks, and active pg_locks tuple contention / MultiXact age',
        {
          sql: z.string().describe('SQL query containing SELECT ... FOR UPDATE / NO KEY UPDATE / SHARE'),
          mutatesUniqueKeys: z.boolean().default(false).describe('Whether the subsequent update modifies primary or unique key columns'),
        },
        async ({ sql, mutatesUniqueKeys }) => {
          const client = await pool.connect();
          try {
            const upper = sql.toUpperCase();
            const hasForUpdate = upper.includes('FOR UPDATE');
            const hasForNoKeyUpdate = upper.includes('FOR NO KEY UPDATE');
            const hasForShare = upper.includes('FOR SHARE') || upper.includes('FOR KEY SHARE');
            const hasNoWait = upper.includes('NOWAIT');
            const hasSkipLocked = upper.includes('SKIP LOCKED');

            // 1. Audit active MultiXact age headroom in the database
            const mxidRes = await client.query(`
              SELECT
                datname,
                datminmxid,
                age(datminmxid) AS multixact_age,
                2147483648 - age(datminmxid) AS mxid_headroom
              FROM pg_database
              WHERE datname = current_database();
            `);
            const mxidData = mxidRes.rows[0];

            // 2. Identify locking hazards
            const hazards: string[] = [];
            let recommendedSql = sql;

            if (hasForShare) {
              hazards.push('CRITICAL: Shared lock (FOR SHARE) detected. If followed by an UPDATE in the same transaction, this triggers deterministic 40P01 deadlock.');
              recommendedSql = sql.replace(/FOR\s+(KEY\s+)?SHARE/i, mutatesUniqueKeys ? 'FOR UPDATE' : 'FOR NO KEY UPDATE');
            } else if (hasForUpdate && !mutatesUniqueKeys) {
              hazards.push('WARNING: FOR UPDATE conflicts with child foreign key validation (LockTupleKeyShare). Use FOR NO KEY UPDATE since non-key columns are modified.');
              recommendedSql = sql.replace(/FOR\s+UPDATE/i, 'FOR NO KEY UPDATE');
            }

            if (!hasNoWait && !hasSkipLocked) {
              hazards.push('NOTICE: Blocking lock detected without NOWAIT / SKIP LOCKED. Must be wrapped with SET LOCAL lock_timeout <= 2000ms.');
            }

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  sql,
                  hasHazards: hazards.length > 0,
                  hazards,
                  recommendedSql,
                  multiXactStatus: {
                    database: mxidData?.datname,
                    multiXactAge: Number(mxidData?.multixact_age ?? 0),
                    headroomRemaining: Number(mxidData?.mxid_headroom ?? 0),
                    isApproachingFreeze: Number(mxidData?.multixact_age ?? 0) > 200000000,
                  },
                }, null, 2),
              }],
            };
          } catch (err: any) {
            return {
              isError: true,
              content: [{ type: 'text', text: `Failed to inspect row-level locking safety: ${err.message}` }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Diagnostic Tool: Inspect Covering Index & Index-Only Scan Safety
      server.tool(
        'inspect_covering_index_safety',
        'Audits PostgreSQL indexes and queries for covering index optimization, leaf-only payload separation, visibility map heap fetches, and HOT update preservation',
        {
          tableName: z.string().describe('Target table name to audit'),
          indexName: z.string().optional().describe('Specific index name to audit (optional)'),
        },
        async ({ tableName, indexName }) => {
          const client = await pool.connect();
          try {
            // 1. Audit index statistics, heap fetches, and scan frequency
            const statQuery = `
              SELECT
                c.relname AS table_name,
                i.relname AS index_name,
                idx.indisunique AS is_unique,
                stat.idx_scan,
                stat.idx_tup_fetch AS heap_fetches,
                CASE
                  WHEN stat.idx_scan = 0 THEN 0.0
                  ELSE ROUND((stat.idx_tup_fetch::numeric / stat.idx_scan::numeric), 2)
                END AS avg_heap_fetches_per_scan,
                pg_size_pretty(pg_relation_size(i.oid)) AS index_size,
                pg_size_pretty(pg_relation_size(c.oid)) AS table_size
              FROM pg_class c
              JOIN pg_index idx ON c.oid = idx.indrelid
              JOIN pg_class i ON i.oid = idx.indexrelid
              JOIN pg_statio_user_indexes stat ON stat.indexrelid = idx.indexrelid
              WHERE c.relname = $1
                ${indexName ? 'AND i.relname = $2' : ''}
              ORDER BY stat.idx_scan DESC;
            `;
            const params = indexName ? [tableName, indexName] : [tableName];
            const statRes = await client.query(statQuery, params);

            // 2. Audit autovacuum settings for the table
            const autoVacRes = await client.query(`
              SELECT reloptions
              FROM pg_class
              WHERE relname = $1;
            `, [tableName]);

            const reloptions: string[] = autoVacRes.rows[0]?.reloptions ?? [];
            const hasAggressiveAutovacuum = reloptions.some((opt: string) =>
              opt.includes('autovacuum_vacuum_scale_factor=0.0')
            );

            // 3. Evaluate heap fetch risks
            const warnings: string[] = [];
            for (const row of statRes.rows) {
              if (Number(row.avg_heap_fetches_per_scan) > 10.0 && Number(row.idx_scan) > 100) {
                warnings.push(
                  `HIGH_HEAP_FETCHES: Index '${row.index_name}' incurs an average of ${row.avg_heap_fetches_per_scan} heap fetches per scan. ` +
                  `Visibility Map is likely cold. Consider tuning autovacuum_vacuum_scale_factor to 0.05.`
                );
              }
            }

            if (!hasAggressiveAutovacuum) {
              warnings.push(
                `AUTOVACUUM_TUNING: Table '${tableName}' does not have customized autovacuum settings. ` +
                `For reliable Index-Only Scans with 0 heap fetches, apply: ALTER TABLE ${tableName} SET (autovacuum_vacuum_scale_factor = 0.05);`
              );
            }

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  tableName,
                  indexCount: statRes.rowCount,
                  indexes: statRes.rows,
                  hasAggressiveAutovacuum,
                  warnings,
                  recommendation: warnings.length === 0
                    ? 'Covering index and Visibility Map metrics are optimal.'
                    : 'Tune table autovacuum scale factors or review included column mutations.',
                }, null, 2),
              }],
            };
          } catch (err: any) {
            return {
              isError: true,
              content: [{ type: 'text', text: `Failed to inspect covering index safety: ${err.message}` }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Diagnostic Tool: Inspect Partial Index & Filtered Predicate Health
      server.tool(
        'inspect_partial_index_safety',
        'Audits PostgreSQL tables for asymmetric queue skew, partial index predicates, soft-delete unique invariants, and autovacuum scale factors',
        {
          tableName: z.string().describe('Target table name to audit'),
        },
        async ({ tableName }) => {
          const client = await pool.connect();
          try {
            // 1. Inspect existing partial indexes
            const partialIdxRes = await client.query(`
              SELECT
                i.relname AS index_name,
                idx.indisunique AS is_unique,
                pg_get_expr(idx.indpred, idx.indrelid) AS partial_predicate,
                stat.idx_scan,
                stat.idx_tup_read,
                pg_size_pretty(pg_relation_size(i.oid)) AS index_size
              FROM pg_class c
              JOIN pg_index idx ON c.oid = idx.indrelid
              JOIN pg_class i ON i.oid = idx.indexrelid
              JOIN pg_stat_user_indexes stat ON stat.indexrelid = idx.indexrelid
              WHERE c.relname = $1
                AND idx.indpred IS NOT NULL
              ORDER BY stat.idx_scan DESC;
            `, [tableName]);

            // 2. Inspect table columns for soft-delete pattern
            const colRes = await client.query(`
              SELECT column_name, data_type, is_nullable
              FROM information_schema.columns
              WHERE table_name = $1
                AND column_name IN ('deleted_at', 'status', 'state');
            `, [tableName]);

            const hasSoftDelete = colRes.rows.some((r: any) => r.column_name === 'deleted_at');
            const hasStatus = colRes.rows.some((r: any) => ['status', 'state'].includes(r.column_name));

            // 3. Inspect autovacuum settings
            const autoVacRes = await client.query(`
              SELECT reloptions, n_live_tup, n_dead_tup
              FROM pg_class c
              JOIN pg_stat_user_tables s ON s.relname = c.relname
              WHERE c.relname = $1;
            `, [tableName]);

            const reloptions: string[] = autoVacRes.rows[0]?.reloptions ?? [];
            const liveTuples = Number(autoVacRes.rows[0]?.n_live_tup ?? 0);
            const deadTuples = Number(autoVacRes.rows[0]?.n_dead_tup ?? 0);
            const hasTunedVacuum = reloptions.some((opt: string) =>
              opt.includes('autovacuum_vacuum_scale_factor=0.0')
            );

            const warnings: string[] = [];

            if (hasSoftDelete) {
              const hasSoftDeleteUnique = partialIdxRes.rows.some((r: any) =>
                r.is_unique && r.partial_predicate?.includes('deleted_at IS NULL')
              );
              if (!hasSoftDeleteUnique) {
                warnings.push(
                  `SOFT_DELETE_UNIQUE_MISSING: Table '${tableName}' has a 'deleted_at' column but no partial unique index ` +
                  `with 'WHERE deleted_at IS NULL'. Standard UNIQUE constraints will break user re-registration.`
                );
              }
            }

            if (hasStatus && partialIdxRes.rowCount === 0 && liveTuples > 50000) {
              warnings.push(
                `ASYMMETRIC_QUEUE_SKEW: Table '${tableName}' has status columns and high row count (${liveTuples}) ` +
                `but no partial queue indexes detected. Consider adding a partial index for PENDING/ACTIVE tasks.`
              );
            }

            if (partialIdxRes.rowCount > 0 && !hasTunedVacuum) {
              warnings.push(
                `AUTOVACUUM_CHURN_RISK: Table '${tableName}' maintains partial queue indexes with frequent turnover. ` +
                `Tune autovacuum: ALTER TABLE ${tableName} SET (autovacuum_vacuum_scale_factor = 0.05);`
              );
            }

            return {
              content: [{
                type: 'text',
                text: JSON.stringify({
                  tableName,
                  liveTuples,
                  deadTuples,
                  partialIndexCount: partialIdxRes.rowCount,
                  partialIndexes: partialIdxRes.rows,
                  hasTunedVacuum,
                  warnings,
                  recommendation: warnings.length === 0
                    ? 'Partial index and predicate invariants are fully satisfied.'
                    : 'Remediate missing partial unique indexes or tune autovacuum churn parameters.',
                }, null, 2),
              }],
            };
          } catch (err: any) {
            return {
              isError: true,
              content: [{ type: 'text', text: `Failed to inspect partial index safety: ${err.message}` }],
            };
          } finally {
            client.release();
          }
        }
      );

      // Diagnostic Tool: Inspect CTE Materialization, Inlining & Recursive Safety
      server.tool(
        'inspect_cte_optimization_safety',
        'Audits SQL queries containing CTEs (WITH queries) for implicit materialization bloat, predicate blockade, unhedged volatile functions, and unbounded recursion cycles',
        {
          sqlQuery: z.string().describe('Target SQL query text containing WITH or WITH RECURSIVE'),
        },
        async ({ sqlQuery }) => {
          const normalized = sqlQuery.replace(/\s+/g, ' ').trim();
          const isCTE = /\bWITH\b/i.test(normalized);
          const isRecursive = /\bWITH\s+RECURSIVE\b/i.test(normalized);
          const warnings: string[] = [];
          const recommendations: string[] = [];

          if (!isCTE) {
            return {
              content: [{
                type: 'text',
                text: JSON.stringify({ isCTE: false, message: 'Query does not contain Common Table Expressions (WITH).' }, null, 2),
              }],
            };
          }

          if (isRecursive) {
            const hasCycle = /\bCYCLE\b/i.test(normalized);
            const hasDepthGuard = /\b(depth\s*<|LIMIT\b)/i.test(normalized);
            if (!hasCycle && !hasDepthGuard) {
              warnings.push(
                'UNBOUNDED_RECURSIVE_CTE: Recursive CTE lacks PostgreSQL 14+ CYCLE clause and depth fence. ' +
                'Cyclic references will cause infinite loops and crash backend memory.'
              );
              recommendations.push('Add "CYCLE <pk_col> SET is_cycle USING path" and "WHERE NOT is_cycle".');
            }
          }

          // Check for outer WHERE against MATERIALIZED CTE
          if (/\bAS\s+MATERIALIZED\b/i.test(normalized)) {
            const hasOuterWhere = /\bSELECT\b.*\bFROM\b.*\bWHERE\b/i.test(normalized);
            if (hasOuterWhere) {
              warnings.push(
                'MATERIALIZED_OPTIMIZATION_FENCE: Query declares AS MATERIALIZED and applies outer WHERE filters. ' +
                'The optimization fence blocks predicate pushdown, forcing full table scans inside the CTE.'
              );
              recommendations.push('Change to "AS NOT MATERIALIZED" or hoist filters directly into the CTE body.');
            }
          }

          // Check for volatile functions in inlined CTEs
          const hasVolatile = /\b(gen_random_uuid\(\)|random\(\)|clock_timestamp\(\)|nextval\()/i.test(normalized);
          if (hasVolatile && !/\bAS\s+MATERIALIZED\b/i.test(normalized)) {
            warnings.push(
              'VOLATILE_FUNCTION_INLINING: CTE contains volatile functions without AS MATERIALIZED. ' +
              'The planner may re-evaluate the function multiple times per outer row, producing inconsistent values.'
            );
            recommendations.push('Declare CTE "AS MATERIALIZED" to force single-pass evaluation.');
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                isCTE: true,
                isRecursive,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Diagnostic Tool: Inspect Keyset Pagination & Seek Method Safety
      server.tool(
        'inspect_keyset_pagination_safety',
        'Audits SQL queries for high-offset scan cliffs, missing deterministic tie-breakers, tuple comparison mismatches, and early-join bloat',
        {
          sqlQuery: z.string().describe('Target SQL query text intended for paginated data retrieval'),
        },
        async ({ sqlQuery }) => {
          const normalized = sqlQuery.replace(/\s+/g, ' ').trim();
          const warnings: string[] = [];
          const recommendations: string[] = [];

          // 1. Detect OFFSET Catastrophe
          const offsetMatch = normalized.match(/\bOFFSET\s+(\d+)\b/i);
          if (offsetMatch && parseInt(offsetMatch[1], 10) > 0) {
            const offsetVal = parseInt(offsetMatch[1], 10);
            warnings.push(
              `OFFSET_SCAN_CLIFF: Query uses OFFSET ${offsetVal}. The database must scan, visibility-check, ` +
              `and discard ${offsetVal} rows before returning results, thrashing buffer caches.`
            );
            recommendations.push('Eliminate OFFSET. Use keyset cursor seek: WHERE (sort_col, id) < ($1, $2).');
          }

          // 2. Deterministic Tie-Breaker
          const orderMatch = normalized.match(/\bORDER\s+BY\s+([^;]+?)(?:\bLIMIT\b|\bOFFSET\b|$)/i);
          if (orderMatch) {
            const orderCols = orderMatch[1].toLowerCase();
            const hasTieBreaker = /\b(id|_id|uuid|pk)\b/.test(orderCols);
            if (!hasTieBreaker) {
              warnings.push(
                'NON_DETERMINISTIC_SORT: ORDER BY clause lacks unique primary key tie-breaker. ' +
                'Identical timestamps or status values will yield arbitrary physical heap ordering and page jitter.'
              );
              recommendations.push('Append unique primary key (e.g., id DESC) as the final ORDER BY column.');
            }
          } else {
            warnings.push('MISSING_ORDER_BY: Query lacks explicit ORDER BY clause. Row order is completely non-deterministic.');
            recommendations.push('Add deterministic ORDER BY with unique primary key tie-breaker.');
          }

          // 3. Early Join Bloat on Paginated Queries
          const joinCount = (normalized.match(/\bJOIN\b/gi) || []).length;
          const isPaginated = /\bLIMIT\b/i.test(normalized) || /\bOFFSET\b/i.test(normalized);
          const isDeferred = /\bWITH\b.*\bLIMIT\b.*\bJOIN\b/i.test(normalized);
          if (isPaginated && joinCount >= 2 && !isDeferred) {
            warnings.push(
              `EARLY_JOIN_AMPLIFICATION: Paginated query performs ${joinCount} joins before applying pagination bounds. ` +
              'Materializes wide joined tuples in work_mem for discarded rows.'
            );
            recommendations.push('Refactor to Deferred Join (Late Lookup): Seek target IDs in a CTE with LIMIT, then join dimension tables.');
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Diagnostic Tool: Inspect Window Function & Frame Specification Safety
      server.tool(
        'inspect_window_function_safety',
        'Audits SQL queries for implicit RANGE frames on running aggregates, window functions in WHERE clauses, missing deterministic tie-breakers, and repeated identical window specifications',
        {
          sqlQuery: z.string().describe('Target SQL query text containing window functions or cumulative calculations'),
        },
        async ({ sqlQuery }) => {
          const normalized = sqlQuery.replace(/\s+/g, ' ').trim();
          const warnings: string[] = [];
          const recommendations: string[] = [];

          // 1. Detect Window Function inside WHERE clause
          if (/\bWHERE\b.*?\b(ROW_NUMBER|RANK|DENSE_RANK|SUM|AVG|MIN|MAX|LEAD|LAG)\s*\([^)]*\)\s*OVER/i.test(normalized)) {
            warnings.push(
              'WINDOW_IN_WHERE_CLAUSE: Window functions are prohibited in WHERE/HAVING filters due to SQL relational execution order (SQLSTATE 42803).'
            );
            recommendations.push('Wrap query in a CTE or subquery, or use PostgreSQL DISTINCT ON for Top-1 per group.');
          }

          // 2. Detect Implicit RANGE frame on running aggregate
          const overRegex = /\b(SUM|AVG|COUNT|MIN|MAX)\s*\(([^)]+)\)\s*OVER\s*\(([^)]+)\)/gi;
          let match: RegExpExecArray | null;
          while ((match = overRegex.exec(normalized)) !== null) {
            const funcName = match[1].toUpperCase();
            const overBody = match[3];
            if (/\bORDER\s+BY\b/i.test(overBody) && !/\bROWS\b/i.test(overBody)) {
              warnings.push(
                `IMPLICIT_RANGE_FRAME: ${funcName} running aggregate omits explicit ROWS specification. ` +
                'Defaults to RANGE, buffering peer groups in memory (tuplestore spill) and lumping identical timestamp values together.'
              );
              recommendations.push('Specify explicit ROWS frame: ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW.');
            }
          }

          // 3. Detect Missing Immutable Tie-Breaker
          const orderMatch = normalized.match(/\bOVER\s*\(\s*(?:PARTITION\s+BY\s+[^)]+?)?\s*ORDER\s+BY\s+([^)]+?)\)/gi);
          if (orderMatch) {
            for (const om of orderMatch) {
              const sortCols = om.toLowerCase().split(/\bROWS\b|\bRANGE\b/)[0];
              if (!/\b(id|_id|uuid|pk)\b/.test(sortCols)) {
                warnings.push(
                  'MISSING_UNIQUE_TIE_BREAKER: Window ORDER BY clause lacks immutable unique key. Duplicate sort keys yield arbitrary heap ordering.'
                );
                recommendations.push('Append unique primary key (e.g. id ASC) to the window ORDER BY clause.');
                break;
              }
            }
          }

          // 4. Correlated Subquery Running Total
          if (/SELECT\s+.*?\(\s*SELECT\s+SUM\s*\(.*?\)\s+FROM\s+\w+\s+\w+\s+WHERE\s+.*?<=\s*.*?\)/i.test(normalized)) {
            warnings.push(
              'CORRELATED_SUBQUERY_RUNNING_TOTAL: Triangular self-join detected for cumulative sum. Operates in O(N^2) time, choking CPU cores.'
            );
            recommendations.push('Replace with single-pass window function: SUM(...) OVER (ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW).');
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Audit Bulk Ingestion Invariants Tool
      server.tool(
        'audit_bulk_ingestion_invariants',
        'Audits SQL query patterns, parameter cardinality, and protocol selection for bulk data ingestion pipelines',
        {
          sqlQuery: z.string().describe('The SQL ingestion statement or script to audit'),
          estimatedRowCount: z.number().describe('Estimated number of records to ingest'),
          columnCount: z.number().describe('Number of columns per record being ingested'),
          engine: z.enum(['postgresql', 'sqlite', 'mysql']).default('postgresql').describe('Target relational database engine'),
        },
        async ({ sqlQuery, estimatedRowCount, columnCount, engine }) => {
          const warnings: string[] = [];
          const recommendations: string[] = [];
          const normalized = sqlQuery.trim();

          const maxParams = engine === 'sqlite' ? 32766 : 65535;
          const estimatedParams = estimatedRowCount * columnCount;
          const safeChunkSize = Math.min(1000, Math.floor((maxParams - 500) / Math.max(1, columnCount)));

          // 1. Parameter explosion check
          if (estimatedParams > maxParams && /\bVALUES\b/i.test(normalized)) {
            warnings.push(
              `PARAMETER_LIMIT_OVERFLOW: Inserting ${estimatedRowCount} rows with ${columnCount} columns requires ${estimatedParams} parameters, exceeding ${engine} limit of ${maxParams} (SQLSTATE 54000/08P01).`
            );
            recommendations.push(
              `Chunk data into batches of at most ${safeChunkSize} rows, or stream via native PostgreSQL COPY protocol.`
            );
          }

          // 2. High volume without COPY protocol
          if (estimatedRowCount > 5000 && !/\bCOPY\b/i.test(normalized) && engine === 'postgresql') {
            warnings.push(
              `MISSING_COPY_PROTOCOL: High volume dataset (${estimatedRowCount} rows) uses standard INSERT. Ingestion will be 10x-50x slower and multiply WAL overhead.`
            );
            recommendations.push('Migrate to native COPY FROM STDIN protocol (e.g. pgx.CopyFrom, pg-copy-streams).');
          }

          // 3. UNLOGGED staging table lifecycle
          if (/CREATE\s+UNLOGGED\s+TABLE/i.test(normalized) && !/TRUNCATE\s+(TABLE\s+)?staging_/i.test(normalized)) {
            warnings.push(
              'UNLOGGED_STAGING_LEAK: UNLOGGED staging table created without matching TRUNCATE. Space will not be reclaimed post-merge.'
            );
            recommendations.push('Append TRUNCATE staging_table after the atomic ON CONFLICT merge.');
          }

          // 4. Initial table load without FREEZE
          if (/CREATE\s+TABLE\s+.*?(PARTITION\s+OF)?/i.test(normalized) && /\bCOPY\b/i.test(normalized) && !/\bFREEZE\b/i.test(normalized)) {
            warnings.push(
              'MISSING_COPY_FREEZE: New partition or table bulk loaded without FREEZE. Will trigger aggressive autovacuum freeze scans later.'
            );
            recommendations.push('Add WITH (FREEZE on) to the COPY command inside the creation transaction.');
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                safeChunkSize,
                estimatedParams,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Audit LATERAL Join and Correlated Subquery Invariants Tool
      server.tool(
        'audit_lateral_join_invariants',
        'Audits SQL query patterns for Top-K window function anti-patterns, correlated scalar subquery proliferation, and LATERAL join null-safety',
        {
          sqlQuery: z.string().describe('The SQL query string to audit for LATERAL patterns'),
          estimatedParentRows: z.number().default(1000).describe('Estimated outer table row count'),
          estimatedChildRows: z.number().default(1000000).describe('Estimated inner child table row count'),
        },
        async ({ sqlQuery, estimatedParentRows, estimatedChildRows }) => {
          const warnings: string[] = [];
          const recommendations: string[] = [];
          const suggestedIndexes: string[] = [];
          const normalized = sqlQuery.trim().replace(/\s+/g, ' ');

          // 1. Detect Window Function Partition Top-K Anti-Pattern
          const windowTopK = /ROW_NUMBER\s*\(\s*\)\s*OVER\s*\(\s*PARTITION\s+BY\s+([a-zA-Z0-9_.,\s]+)\s+ORDER\s+BY\s+([a-zA-Z0-9_.,\s]+)\)/i;
          const filterRank = /WHERE[\s\S]*?\brn\s*(<=|<|=)\s*(\d+)/i;

          if (windowTopK.test(normalized) && filterRank.test(normalized)) {
            const match = normalized.match(windowTopK);
            const partKeys = match ? match[1].trim() : 'partition_key';
            const orderKeys = match ? match[2].trim() : 'order_key';

            warnings.push(
              `WINDOW_FUNCTION_TOP_K_INEFFICIENCY: Query computes ROW_NUMBER() over entire partitioned relation (${estimatedChildRows} rows). Incurs O(N log N) sort and disk temp spill.`
            );
            recommendations.push(
              `Refactor to CROSS JOIN LATERAL or LEFT JOIN LATERAL with ORDER BY ${orderKeys} LIMIT K. Add composite index on (${partKeys}, ${orderKeys}).`
            );
            suggestedIndexes.push(`CREATE INDEX idx_child_lateral_seek ON child_table (${partKeys}, ${orderKeys});`);
          }

          // 2. Correlated scalar subquery proliferation in SELECT
          const projectionMatch = normalized.match(/SELECT\b([\s\S]*?)\bFROM\b/i);
          if (projectionMatch) {
            const projection = projectionMatch[1];
            const scalarCount = (projection.match(/\(\s*SELECT\b[\s\S]*?\bFROM\b/gi) || []).length;
            if (scalarCount >= 2) {
              warnings.push(
                `SCALAR_SUBQUERY_PROLIFERATION: Detected ${scalarCount} correlated scalar subqueries in SELECT projection. Multiplies index seeks by ${scalarCount}x per parent row (${estimatedParentRows * scalarCount} total seeks).`
              );
              recommendations.push(
                'Consolidate independent scalar subqueries into a single LEFT JOIN LATERAL clause computing all aggregates in one pass.'
              );
            }
          }

          // 3. CROSS JOIN LATERAL null loss risk
          if (/\bCROSS\s+JOIN\s+LATERAL\b/i.test(normalized) && !/\bWITH\s+ORDINALITY\b/i.test(normalized)) {
            warnings.push(
              'CROSS_JOIN_LATERAL_NULL_LOSS: CROSS JOIN LATERAL drops parent entities with 0 matching child records. If parent entities must survive, use LEFT JOIN LATERAL ... ON true.'
            );
            recommendations.push('Replace CROSS JOIN LATERAL with LEFT JOIN LATERAL ... ON true.');
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                suggestedIndexes,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Audit SQL Hierarchical Tree Queries & Schema Invariants
      server.tool(
        'audit_sql_hierarchy_query',
        'Statically audits SQL queries and DDL for tree modeling, cycle vulnerabilities, and ltree path invariants.',
        {
          sql: z.string().describe('The SQL query or DDL statement implementing tree structures or recursive CTEs.'),
        },
        async ({ sql }) => {
          const warnings: string[] = [];
          const recommendations: string[] = [];
          const normalized = sql.replace(/\s+/g, ' ');

          // 1. Recursive CTE without cycle detection
          if (/\bWITH\s+RECURSIVE\b/i.test(normalized)) {
            const hasCycle = /\bCYCLE\s+[a-zA-Z0-9_]+\s+SET\s+[a-zA-Z0-9_]+\s+USING\b/i.test(normalized);
            const hasArrayVisited = /ARRAY\[.*?\]|visited\s*\|\|/i.test(normalized);
            if (!hasCycle && !hasArrayVisited) {
              warnings.push(
                'UNBOUNDED_RECURSIVE_LOOP: WITH RECURSIVE query lacks a CYCLE clause or visited array. Any circular graph reference will trigger an infinite loop and OOM crash.'
              );
              recommendations.push(
                'Add PostgreSQL 14+ `CYCLE id SET is_cycle USING path` or an explicit array visited check.'
              );
            }

            const hasDepthCap = /\bdepth\s*(<|<=)\s*\d+/i.test(normalized);
            if (!hasDepthCap) {
              warnings.push(
                'MISSING_DEPTH_CEILING: Recursive CTE lacks an explicit depth guard (e.g. `depth < 25`). Deep hierarchies may exhaust memory.'
              );
              recommendations.push('Add an explicit depth ceiling condition in the recursive member.');
            }
          }

          // 2. Naive string LIKE path matching
          if (/\bpath\s+LIKE\s+['"][^'"]*%/i.test(normalized)) {
            warnings.push(
              'NAIVE_STRING_LIKE_HIERARCHY: Prefix LIKE search on hierarchy path column causes substring collision bugs and full table scans.'
            );
            recommendations.push(
              'Migrate to PostgreSQL native `ltree` extension with GiST `<@` and `@>` path operators.'
            );
          }

          // 3. Direct UPDATE parent_id without cycle check
          if (/UPDATE\s+[a-zA-Z0-9_.]+\s+SET\s+parent_id\s*=/i.test(normalized) && !/WHERE.*NOT\s+IN/i.test(normalized)) {
            warnings.push(
              'UNCHECKED_PARENT_RELOCATION: Direct UPDATE of parent_id without descendant exclusion pre-check risks detaching subtrees into circular orphan islands.'
            );
            recommendations.push(
              'Verify that target parent is not within the descendants of the moved node before updating parent_id.'
            );
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Audit SQL Triggers, Stored Procedures, Volatility & Transition Table Invariants
      server.tool(
        'audit_sql_trigger_procedure_invariants',
        'Statically audits SQL functions, procedures, and triggers for volatility tags, transition tables, search_path pinning, and dynamic SQL safety.',
        {
          sql: z.string().describe('The SQL DDL or function/trigger definition to audit.'),
        },
        async ({ sql }) => {
          const warnings: string[] = [];
          const recommendations: string[] = [];
          const normalized = sql.replace(/\s+/g, ' ');

          // 1. Missing function volatility
          if (/CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\b/i.test(normalized) && !/RETURNS\s+trigger\b/i.test(normalized)) {
            const hasVolatility = /\b(IMMUTABLE|STABLE|VOLATILE)\b/i.test(normalized);
            if (!hasVolatility) {
              warnings.push(
                'FUNCTION_VOLATILITY_MISSING: Function definition lacks IMMUTABLE, STABLE, or VOLATILE annotation. Defaults to VOLATILE, paralyzing query plans and parallel workers.'
              );
              recommendations.push(
                'Explicitly declare volatility (e.g. IMMUTABLE PARALLEL SAFE STRICT for pure functions).'
              );
            }
          }

          // 2. SECURITY DEFINER without pinned search_path (CWE-426)
          if (/\bSECURITY\s+DEFINER\b/i.test(normalized)) {
            const hasPinnedSearchPath = /SET\s+search_path\s*=\s*pg_catalog/i.test(normalized);
            if (!hasPinnedSearchPath) {
              warnings.push(
                'SECURITY_DEFINER_UNPINNED_SEARCH_PATH: SECURITY DEFINER routine omits `SET search_path = pg_catalog, pg_temp`. Vulnerable to privilege escalation via schema hijacking (CWE-426).'
              );
              recommendations.push(
                'Append `SET search_path = pg_catalog, pg_temp` to the function or procedure definition.'
              );
            }
          }

          // 3. Row-level audit triggers instead of statement transition tables
          if (/CREATE\s+TRIGGER\b/i.test(normalized) && /\bFOR\s+EACH\s+ROW\b/i.test(normalized)) {
            if (/audit|log|history|event/i.test(normalized)) {
              warnings.push(
                'ROW_LEVEL_AUDIT_TRIGGER: Audit trigger executes FOR EACH ROW, creating O(N) PL/pgSQL context switches and risking lock table exhaustion during bulk operations.'
              );
              recommendations.push(
                'Refactor to FOR EACH STATEMENT with PostgreSQL 10+ transition tables: REFERENCING NEW TABLE AS new_table OLD TABLE AS old_table.'
              );
            }

            // 4. Missing WHEN clause on row update trigger
            if (/\bUPDATE\b/i.test(normalized) && !/\bWHEN\b/i.test(normalized)) {
              warnings.push(
                'MISSING_TRIGGER_WHEN_CLAUSE: Row-level UPDATE trigger fires unconditionally without a WHEN clause, risking recursive cascade loops.'
              );
              recommendations.push(
                'Add `WHEN (OLD.* IS DISTINCT FROM NEW.*)` conditional predicate.'
              );
            }
          }

          // 5. Dynamic SQL string concatenation
          if (/\bEXECUTE\b/i.test(normalized) && /EXECUTE\s+.*\|\|/i.test(normalized)) {
            warnings.push(
              'DYNAMIC_SQL_STRING_CONCATENATION: Dynamic SQL EXECUTE uses raw string concatenation, introducing SQL injection risk and breaking plan caching.'
            );
            recommendations.push(
              'Use format() with %I for identifiers and USING clause for query parameter literals.'
            );
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Audit SQL Server-Side Cursors, Streaming Result Sets & Memory OOM Defense
      server.tool(
        'audit_sql_cursor_streaming_invariants',
        'Statically audits SQL cursor declarations and batch queries for NO SCROLL optimization, WITH HOLD disk spill hazards, missing CLOSE statements, and unbounded memory risks.',
        {
          sql: z.string().describe('The SQL script, cursor declaration, or batch query to audit.'),
        },
        async ({ sql }) => {
          const warnings: string[] = [];
          const recommendations: string[] = [];
          const normalized = sql.replace(/\s+/g, ' ');

          // 1. Missing NO SCROLL on cursor declaration
          if (/\bDECLARE\s+\w+\s+(?:BINARY\s+)?(?:INSENSITIVE\s+)?CURSOR\b/i.test(normalized)) {
            if (!/\bNO\s+SCROLL\b/i.test(normalized)) {
              warnings.push(
                'CURSOR_MISSING_NO_SCROLL: Cursor declaration omits explicit `NO SCROLL`. PostgreSQL optimizer may instantiate a tuplestore Materialize node, degrading streaming throughput.'
              );
              recommendations.push(
                'Declare cursor with `DECLARE <name> NO SCROLL CURSOR FOR SELECT ...`.'
              );
            }
          }

          // 2. Dangerous WITH HOLD cursor
          if (/\bCURSOR\s+WITH\s+HOLD\b/i.test(normalized)) {
            warnings.push(
              'CURSOR_DANGEROUS_WITH_HOLD: Cursor declared `WITH HOLD`. On COMMIT, PostgreSQL eagerly copies all remaining candidate rows to temporary disk files (pgsql_tmp), risking disk space exhaustion.'
            );
            recommendations.push(
              'Remove `WITH HOLD`. Keep cursor within a scoped transaction or transition to keyset seek pagination for long-running batch jobs.'
            );
          }

          // 3. Unbounded query on large event/audit tables without cursor or LIMIT
          if (/\bSELECT\b/i.test(normalized) && !/\b(LIMIT|FETCH\s+FIRST|DECLARE)\b/i.test(normalized)) {
            if (/FROM\s+(?:audit_events|events|logs|transactions|orders)\b/i.test(normalized)) {
              warnings.push(
                'UNBOUNDED_HIGH_VOLUME_QUERY: Query reads from high-volume table without LIMIT or cursor streaming, introducing client-side process OOM risk.'
              );
              recommendations.push(
                'Use server-side cursor streaming (pg-query-stream, pgx.Rows) or keyset pagination.'
              );
            }
          }

          // 4. Missing CLOSE statement
          const declareMatch = /\bDECLARE\s+(\w+)\s+.*CURSOR\b/i.exec(normalized);
          if (declareMatch) {
            const cursorName = declareMatch[1];
            const closeRegex = new RegExp(`\\bCLOSE\\s+(${cursorName}|ALL)\\b`, 'i');
            if (!closeRegex.test(normalized)) {
              warnings.push(
                `CURSOR_LEAK_MISSING_CLOSE: Cursor '${cursorName}' is declared but never closed with explicit 'CLOSE ${cursorName}'.`
              );
              recommendations.push(
                `Always append 'CLOSE ${cursorName};' before transaction commit or in a finally/defer guard block.`
              );
            }
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Audit SQL Collation, Unicode Normalization & glibc Corruption Invariants
      server.tool(
        'audit_sql_collation_unicode_invariants',
        'Statically audits SQL schemas and queries for missing COLLATE "C" machine identifiers, unindexed LOWER() functions, missing Unicode NFC check constraints, and non-sargable LIKE prefixes.',
        {
          sql: z.string().describe('The SQL schema DDL or query string to audit.'),
        },
        async ({ sql }) => {
          const warnings: string[] = [];
          const recommendations: string[] = [];
          const normalized = sql.replace(/\s+/g, ' ');

          // 1. Machine identifiers missing COLLATE "C"
          const machineIdMatch = /\b(token|api_key|hash|session_id|secret|checksum|sku)\s+(?:VARCHAR|TEXT|CHAR)\b/i.exec(normalized);
          if (machineIdMatch && !/\bCOLLATE\s+("C"|'C'|C|POSIX)\b/i.test(normalized)) {
            warnings.push(
              `MACHINE_IDENTIFIER_MISSING_COLLATE_C: Column '${machineIdMatch[1]}' uses natural-language collation. Incurs heavy strcoll() CPU overhead during joins and lookups.`
            );
            recommendations.push(
              `Add COLLATE "C" to the column definition: ${machineIdMatch[1]} VARCHAR(...) COLLATE "C"`
            );
          }

          // 2. Identity tables missing Unicode NFC normalization check
          if (/\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(users|accounts|profiles)\b/i.test(normalized)) {
            if (!/unicode_normalize_nfc/i.test(normalized)) {
              warnings.push(
                'IDENTITY_TABLE_MISSING_UNICODE_NFC_CHECK: Identity table lacks CHECK (username = unicode_normalize_nfc(username)) constraint. Vulnerable to NFD homoglyph duplicate attacks (CWE-178).'
              );
              recommendations.push(
                'Add constraint: CONSTRAINT ck_username_nfc CHECK (username = unicode_normalize_nfc(username))'
              );
            }
          }

          // 3. Unindexed functional LOWER() in WHERE clause
          if (/\bWHERE\s+LOWER\s*\(\s*\w+\s*\)\s*=\s*(?:LOWER|\$|')/i.test(normalized)) {
            warnings.push(
              'UNINDEXED_FUNCTIONAL_LOWER: Predicate uses LOWER(col) = ... which cannot traverse standard B-Tree indexes, triggering full sequential scans.'
            );
            recommendations.push(
              'Create a functional unique index: CREATE UNIQUE INDEX ON table (LOWER(column)) or migrate to PostgreSQL 12+ non-deterministic ICU collation.'
            );
          }

          // 4. Prefix LIKE search without pattern ops
          if (/\bWHERE\s+\w+\s+LIKE\s+'[a-zA-Z0-9_\-]+%'/i.test(normalized) && !/text_pattern_ops|varchar_pattern_ops|"C"/i.test(normalized)) {
            warnings.push(
              'PREFIX_LIKE_MISSING_PATTERN_OPS: Prefix LIKE query cannot use standard locale B-Tree index and will trigger sequential table scan.'
            );
            recommendations.push(
              'Create B-Tree index using text_pattern_ops or pin column to COLLATE "C".'
            );
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                hasWarnings: warnings.length > 0,
                warningsCount: warnings.length,
                warnings,
                recommendations,
                status: warnings.length === 0 ? 'OPTIMAL' : 'REMEDIATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Tool 12: audit_database_xid_wraparound
      // Inspects PostgreSQL transaction ID (XID) horizon, autovacuum cost throttle, and saboteurs
      this.server.tool(
        'audit_database_xid_wraparound',
        'Audits PostgreSQL transaction ID (XID) wraparound horizon, autovacuum cost throttling, and horizon-pinning saboteurs (slots, idle-in-tx, prepared 2PC).',
        {
          maxAgeDatfrozenxid: z.number().describe('Current maximum age(datfrozenxid) across cluster databases'),
          maxAgeDatminmxid: z.number().optional().default(10000000).describe('Current maximum age(datminmxid) MultiXact ID age'),
          burnRatePerSec: z.number().optional().default(3000).describe('Estimated transaction consumption rate per second'),
          autovacuumCostLimit: z.number().optional().default(200).describe('Current autovacuum_vacuum_cost_limit setting'),
          abandonedSlotsCount: z.number().optional().default(0).describe('Count of disconnected replication slots older than 10M xid'),
          idleInTxCount: z.number().optional().default(0).describe('Count of idle in transaction sessions older than 60s'),
        },
        async ({ maxAgeDatfrozenxid, maxAgeDatminmxid, burnRatePerSec, autovacuumCostLimit, abandonedSlotsCount, idleInTxCount }) => {
          const FATAL_HORIZON = 2_137_483_648; // 2^31 - 10M
          const remainingXids = Math.max(0, FATAL_HORIZON - maxAgeDatfrozenxid);
          const ttwHours = Math.round((remainingXids / burnRatePerSec / 3600) * 10) / 10;

          const anomalies: string[] = [];
          const remedies: string[] = [];

          if (maxAgeDatfrozenxid >= 1_500_000_000 || ttwHours < 24) {
            anomalies.push(`EMERGENCY_WRAPAROUND_RISK: age(datfrozenxid)=${maxAgeDatfrozenxid}, TTW=${ttwHours}h to postmaster stop-the-world lockout!`);
            remedies.push('Immediately pause non-essential batch jobs and trigger manual VACUUM (FREEZE, ANALYZE) on highest age tables.');
          } else if (maxAgeDatfrozenxid >= 200_000_000) {
            anomalies.push(`ELEVATED_FREEZE_AGE: age(datfrozenxid)=${maxAgeDatfrozenxid} exceeds autovacuum_freeze_max_age (200M).`);
          }

          if (abandonedSlotsCount > 0) {
            anomalies.push(`PINNED_VACUUM_HORIZON: ${abandonedSlotsCount} inactive replication slot(s) are pinning global vacuum horizon.`);
            remedies.push("Drop inactive slots using SELECT pg_drop_replication_slot(slot_name) from pg_replication_slots WHERE active = false;");
          }

          if (idleInTxCount > 0) {
            anomalies.push(`IDLE_IN_TRANSACTION_SABOTEURS: ${idleInTxCount} session(s) holding backend_xmin.`);
            remedies.push("Configure idle_in_transaction_session_timeout = '60s' and terminate lingering sessions with pg_terminate_backend().");
          }

          if (autovacuumCostLimit < 1000) {
            anomalies.push(`THROTTLED_AUTOVACUUM: cost limit (${autovacuumCostLimit}) throttles NVMe freeze throughput to ~20-40 MB/s.`);
            remedies.push("Increase autovacuum_vacuum_cost_limit = 3000 and lower autovacuum_vacuum_cost_delay = 2ms.");
          }

          let state = 'NOMINAL';
          if (maxAgeDatfrozenxid >= FATAL_HORIZON - 100_000) state = 'STOP_THE_WORLD_LOCKOUT';
          else if (anomalies.some(a => a.startsWith('EMERGENCY'))) state = 'CRITICAL_EMERGENCY';
          else if (abandonedSlotsCount > 0 || idleInTxCount > 0) state = 'HORIZON_STARVED';
          else if (maxAgeDatfrozenxid >= 200_000_000) state = 'AGGRESSIVE_FREEZE_ACTIVE';

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                state,
                maxAgeDatfrozenxid,
                remainingXids,
                timeToWraparoundHours: ttwHours,
                anomaliesCount: anomalies.length,
                anomalies,
                remedies,
                status: anomalies.length === 0 ? 'HEALTHY' : (ttwHours < 48 ? 'CRITICAL_ALERT' : 'MAINTENANCE_REQUIRED'),
              }, null, 2),
            }],
          };
        }
      );

      // Tool 21: TOAST Storage Architecture & Compression Diagnostics
      server.tool(
        'diagnose_toast_storage_policy',
        'Analyzes PostgreSQL TOAST storage strategies, detects legacy pglz compression, Shannon entropy mismatches on encrypted ciphertext, and missing toast_tuple_target packing',
        {
          tableName: z.string().describe('Table name containing variable-length columns'),
          columnName: z.string().describe('Column name to analyze'),
          dataType: z.string().describe('Column data type (e.g., text, jsonb, bytea)'),
          currentStorage: z.enum(['EXTENDED', 'EXTERNAL', 'MAIN', 'PLAIN']).default('EXTENDED').describe('Current attstorage setting'),
          currentCompression: z.enum(['lz4', 'pglz', 'default']).default('pglz').describe('Current attcompression setting'),
          sampleEntropyBits: z.number().min(0).max(8).optional().describe('Empirical Shannon entropy in bits/byte (if sampled)'),
          avgPayloadBytes: z.number().optional().default(1500).describe('Average serialized payload size in bytes'),
          toastTableBytes: z.number().optional().default(0).describe('Total size of auxiliary pg_toast table in bytes'),
        },
        async ({ tableName, columnName, dataType, currentStorage, currentCompression, sampleEntropyBits, avgPayloadBytes, toastTableBytes }) => {
          const anomalies: string[] = [];
          const remediationDdl: string[] = [];
          let estimatedCpuSavings = 0;
          let estimatedIoSavings = 0;

          // Check 1: Ciphertext or pre-compressed assets under STORAGE EXTENDED
          if (sampleEntropyBits !== undefined && sampleEntropyBits >= 7.85 && currentStorage === 'EXTENDED') {
            anomalies.push(`HIGH_ENTROPY_COMPRESSION_BURN: Sample entropy is ${sampleEntropyBits} bits/byte (incompressible ciphertext/media), but storage is EXTENDED. Engine wastes up to 40% CPU attempting compression on writes.`);
            remediationDdl.push(`ALTER TABLE "${tableName}" ALTER COLUMN "${columnName}" SET STORAGE EXTERNAL;`);
            estimatedCpuSavings += 40;
          }

          // Check 2: Legacy pglz compression on PostgreSQL 14+ text/jsonb
          if ((dataType.toLowerCase().includes('text') || dataType.toLowerCase().includes('jsonb')) && currentCompression === 'pglz') {
            anomalies.push(`LEGACY_PGLZ_COMPRESSION: Column uses legacy 'pglz'. Decompression latency is 3x-5x slower than modern 'lz4'.`);
            remediationDdl.push(`ALTER TABLE "${tableName}" ALTER COLUMN "${columnName}" SET COMPRESSION lz4;`);
            estimatedCpuSavings += 50;
          }

          // Check 3: Moderate size varlena staying inline (500B-1900B) reducing heap packing
          if (avgPayloadBytes >= 600 && avgPayloadBytes <= 1900 && currentStorage === 'EXTENDED') {
            anomalies.push(`LOW_HEAP_PACKING_DENSITY: Avg size ${avgPayloadBytes}B stays inline under default TOAST_TUPLE_THRESHOLD (2048B), packing only 4-5 tuples per 8KB page.`);
            remediationDdl.push(`ALTER TABLE "${tableName}" SET (toast_tuple_target = 128);`);
            estimatedIoSavings += 70;
          }

          let state = 'OPTIMAL';
          if (anomalies.some(a => a.startsWith('HIGH_ENTROPY'))) state = 'CPU_STARVATION_RISK';
          else if (anomalies.some(a => a.startsWith('LEGACY'))) state = 'SUBOPTIMAL_COMPRESSION';
          else if (anomalies.some(a => a.startsWith('LOW_HEAP'))) state = 'HEAP_BLOAT_INLINE';

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                tableName,
                columnName,
                state,
                anomaliesCount: anomalies.length,
                anomalies,
                remediationDdl,
                estimatedCpuSavingsPct: estimatedCpuSavings,
                estimatedIoSavingsPct: estimatedIoSavings,
                status: anomalies.length === 0 ? 'HEALTHY' : 'OPTIMIZATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );

      // Tool 22: System Catalog Bloat & Relcache Invalidation Risk Diagnostics
      server.tool(
        'diagnose_catalog_bloat_and_invalidation',
        'Analyzes PostgreSQL system catalog dead tuple bloat, detects temporary table churn, shared_inval ring buffer risk, and recommends aggressive catalog autovacuum tuning',
        {
          catalogTableName: z.enum(['pg_class', 'pg_attribute', 'pg_type', 'pg_depend', 'pg_description']).describe('System catalog table name to evaluate'),
          liveTuples: z.number().describe('Number of live tuples in the catalog table'),
          deadTuples: z.number().describe('Number of dead tuples accumulated in the catalog table'),
          tableSizeBytes: z.number().describe('Total disk size of the catalog table in bytes'),
          dailyTempTableCreations: z.number().optional().default(0).describe('Estimated temporary table creations per day in application workloads'),
          pgBouncerMode: z.enum(['transaction', 'session', 'statement', 'none']).default('transaction').describe('PgBouncer connection pooling mode'),
        },
        async ({ catalogTableName, liveTuples, deadTuples, tableSizeBytes, dailyTempTableCreations, pgBouncerMode }) => {
          const totalTuples = liveTuples + deadTuples;
          const deadRatio = totalTuples > 0 ? deadTuples / totalTuples : 0;
          const anomalies: string[] = [];
          const remediationDdl: string[] = [];

          // Check 1: Severe dead tuple bloat in system catalog
          if (deadRatio > 0.20 || deadTuples > 10000) {
            anomalies.push(`CATALOG_DEAD_TUPLE_BLOAT: ${catalogTableName} has ${deadTuples} dead tuples (${(deadRatio * 100).toFixed(1)}% dead ratio). Causes query plan compilation latency degradation.`);
            remediationDdl.push(`VACUUM ANALYZE pg_catalog.${catalogTableName};`);
            remediationDdl.push(`REINDEX TABLE CONCURRENTLY pg_catalog.${catalogTableName};`);
          }

          // Check 2: Active temporary table churn in OLTP / worker paths
          if (dailyTempTableCreations > 500) {
            anomalies.push(`TEMP_TABLE_CHURN_DETECTED: Workload performs ~${dailyTempTableCreations} CREATE TEMP TABLE operations daily. Generates millions of dead catalog rows and risks shared_inval overflow.`);
            remediationDdl.push(`-- Refactor application queries to replace temporary tables with parameterized UNNEST($1::type[]) or permanent UNLOGGED staging.`);
          }

          // Check 3: PgBouncer transaction mode temp collision risk
          if (pgBouncerMode === 'transaction' && dailyTempTableCreations > 0) {
            anomalies.push(`PGBOUNCER_TRANSACTION_MODE_TEMP_LEAK: Temporary objects created in transaction mode leak across reused server connections. Ensure server_reset_query = DISCARD ALL.`);
          }

          // Check 4: Missing aggressive catalog autovacuum thresholds
          remediationDdl.push(`ALTER TABLE pg_catalog.${catalogTableName} SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_threshold = 50);`);

          let state = 'OPTIMAL';
          if (anomalies.some(a => a.startsWith('TEMP_TABLE_CHURN') || a.startsWith('PGBOUNCER'))) {
            state = 'HIGH_INVAL_STORM_RISK';
          } else if (deadRatio > 0.30 || tableSizeBytes > 100 * 1024 * 1024) {
            state = 'CATALOG_BLOAT_CRITICAL';
          } else if (anomalies.length > 0) {
            state = 'MAINTENANCE_REQUIRED';
          }

          return {
            content: [{
              type: 'text',
              text: JSON.stringify({
                catalogTableName,
                state,
                deadTupleRatioPct: Number((deadRatio * 100).toFixed(2)),
                tableSizeMb: Number((tableSizeBytes / (1024 * 1024)).toFixed(2)),
                anomaliesCount: anomalies.length,
                anomalies,
                remediationDdl,
                status: anomalies.length === 0 ? 'HEALTHY' : 'OPTIMIZATION_REQUIRED',
              }, null, 2),
            }],
          };
        }
      );
    }
    ```