---
description: WebSockets, Server-Sent Events (SSE), and real-time streaming production invariants, connection heartbeats, reconnection storm defense, backpressure, and horizontal cluster scaling
globs: **/*{ws,websocket,realtime,sse,stream,socket,chat}*.*
alwaysApply: false
---

# WebSockets, Server-Sent Events (SSE) & Real-Time Streaming Invariants

> Add these rules to your project if developing real-time features, chat systems, collaborative editors, LLM token streaming endpoints, live telemetry dashboards, or WebSocket/SSE gateways (Node.js, Go, Python, Rust, TypeScript).

---

## 1. Protocol Selection: SSE vs WebSockets
Choose the simplest protocol that satisfies communication symmetry:

| Capability | Server-Sent Events (SSE) | WebSockets (WS/WSS) |
| :--- | :--- | :--- |
| **Directionality** | Unidirectional (Server ──► Client) | Bidirectional (Duplex) (Client ◄──► Server) |
| **Transport** | Standard HTTP/1.1 or HTTP/2 & 3 | TCP socket upgrade (RFC 6455) |
| **Data Format** | UTF-8 text / JSON streaming | Binary (ArrayBuffer) + UTF-8 text |
| **Auto-Reconnect** | Native in browser `EventSource` (`Last-Event-ID`) | Must be implemented manually |
| **Multiplexing** | Native HTTP/2 multiplexing over single TCP conn | Requires separate TCP connection per socket |
| **Best Used For** | **LLM token streaming**, notifications, live feeds, dashboards | **Interactive chat**, collaborative canvases, CRDTs, gaming |

- ❌ **STRICT BAN ON CLIENT SHORT-POLLING**:
  - Never implement real-time updates via `setInterval(() => fetch('/api/status'), 1000)`. Short-polling creates massive database query spikes and connection churn. Always use SSE or WebSockets.
- **Prefer SSE for LLM Generation & One-Way Push**:
  - For AI chat completion streaming or task progress feeds, always prefer SSE over WebSockets. SSE works seamlessly with corporate firewalls, reverse proxies (Cloudflare, Nginx), requires no custom framing, and traverses HTTP/2 multiplexing out of the box.

---

## 2. Heartbeats, Ping/Pong Frames & Dead Connection Pruning
- **The Silent Connection Drop Trap (NAT / ALB Timeouts)**:
  - AWS ALBs, Cloudflare, and cellular network towers silently sever idle TCP connections after 60–120 seconds without emitting TCP `RST` or `FIN` packets. Both client and server think the connection is alive, leaking memory and leaving sockets in zombie states.
- **WebSocket Native Ping/Pong Framing Contract**:
  - The server MUST send a standard WebSocket `Ping` control frame (opcode `0x9`) at deterministic intervals (e.g., every 30 seconds).
  - The client (or browser network stack) automatically responds with a `Pong` frame (opcode `0xA`).
  - If the server receives no response within a strict `pong_timeout` (e.g., 10 seconds), the server MUST terminate the socket immediately:
    ```go
    // Go gorilla/websocket / nhooyr idiom:
    conn.SetReadDeadline(time.Now().Add(pongWait))
    conn.SetPongHandler(func(string) error {
        conn.SetReadDeadline(time.Now().Add(pongWait))
        return nil
    })
    ```
- **SSE Keepalive Comments**:
  - Because SSE runs on standard HTTP, it does not have binary Ping frames.
  - The server MUST write an SSE comment line (`: keepalive\n\n` or `: ping\n\n`) every 15 to 30 seconds to flush buffers and prevent proxy dropouts.

---

## 3. Reconnection Storm Defense & Jittered Backoff
- **The Thundering Herd Disaster**:
  - When a server pod restarts or an internet outage resolves, thousands of clients reconnect at the exact same second, causing CPU spikes, database connection exhaustion, and cascading cluster failures.
- **Mandatory Exponential Backoff with Full Jitter**:
  - Client reconnection loops MUST use exponential backoff with full randomization:
    ```ts
    class ResilientWebSocket {
      private attempt = 0;
      private readonly baseDelay = 1000; // 1s
      private readonly maxDelay = 30000; // 30s

      private getNextBackoff(): number {
        // Full jitter: Uniform random between 0 and min(maxDelay, baseDelay * 2^attempt)
        const max = Math.min(this.maxDelay, this.baseDelay * Math.pow(2, this.attempt));
        this.attempt++;
        return Math.random() * max;
      }
    }
    ```
- **Monotonic Message IDs & Replay Buffers for Gapless Reconnect**:
  - Every message transmitted over the real-time channel MUST include a monotonic sequence ID or millisecond timestamp (`id`).
  - Upon reconnection, the client sends its `last_received_id` (via SSE `Last-Event-ID` header or initial WS sync payload).
  - The server replays any missed messages from a recent buffer (e.g., Redis Stream or in-memory ring buffer) to eliminate message drops across network blips.

---

## 4. Backpressure, Bounded Queues & Slow Consumer Eviction
- **The Bufferbloat & OOM Trap**:
  - If a client is on a degraded mobile network (high packet loss, slow bandwidth) while the server streams events at high throughput, an unbounded send queue will consume unlimited heap memory until the server crashes with Out Of Memory (OOM).
- **Mandatory Bounded Outbound Buffers**:
  - Every connected client MUST have a strictly bounded write queue (e.g., 256 messages).
- **Slow Consumer Policy**:
  - When the client's write buffer becomes full, do NOT block the publisher or allocate unbounded memory:
    1. **For Ephemeral State (e.g. mouse pointers, telemetry)**: Drop the oldest unread frames (`ring_buffer.drop_oldest()`).
    2. **For Critical Messages (e.g. chat messages, transactions)**: Immediately terminate the connection with WebSocket Close Code `1008 (Policy Violation)`:
       ```go
       select {
       case client.sendQueue <- msg:
       default:
           // Slow consumer: buffer full, evict to protect server health
           client.closeWithReason(websocket.ClosePolicyViolation, "client read buffer overflow")
       }
       ```

---

## 5. Horizontal Scaling, Cluster Fanout & Multi-Node Routing
- ❌ **NEVER STORE REAL-TIME SESSIONS IN LOCAL IN-MEMORY GLOBALS**:
  - In multi-replica Kubernetes or serverless environments, Client A connected to Pod 1 will not receive messages published by Client B connected to Pod 2 if state is local.
- **Distributed Pub/Sub Adapter (Redis Streams / NATS / Kafka)**:
  - Decouple connection management from message routing.
  - When an event occurs on Pod 1, publish it to a shared broker channel (`events:room:42`).
  - Every pod subscribed to `events:room:42` forwards the payload only to its own locally connected sockets.
- **Multi-Tenant Channel Scoping**:
  - Topic channels MUST be prefixed with tenant IDs to prevent cross-tenant data leakage:
    ```text
    tenant:{tenant_id}:channel:{channel_id}
    ```

---

## 6. Graceful Shutdown & Client Draining
- **Zero-Downtime Rolling Deployment**:
  - When a server receives `SIGTERM`, it must NOT abruptly drop active TCP sockets (which causes browser errors and reconnect storms).
- **Two-Phase Connection Drain**:
  1. Stop accepting new WebSocket upgrades and SSE connections.
  2. Send WebSocket Close Code `1001 (Going Away)` to existing clients over a staggered drain period (e.g., smoothly across 5 to 10 seconds).
  3. Close Code `1001` instructs standards-compliant clients to immediately reconnect to an alternate healthy upstream pod without showing error banners to end users.

---

## 7. Security, Origin Validation & Handshake Authentication
- 🛡️ **Cross-Site WebSocket Hijacking (CSWSH) Defense**:
  - WebSockets are **NOT** protected by the browser's Same-Origin Policy! Browsers automatically attach existing session cookies to cross-origin WebSocket requests initiated by malicious websites.
  - The server MUST validate the HTTP `Origin` header during the handshake against an explicit whitelist of allowed origins:
    ```go
    var upgrader = websocket.Upgrader{
        CheckOrigin: func(r *http.Request) bool {
            origin := r.Header.Get("Origin")
            return isAllowedOrigin(origin) // ❌ NEVER return unconditional `true`
        },
    }
    ```
- **Handshake Authentication Discipline**:
  - ❌ **NEVER pass long-lived JWTs or API keys in query parameters**:
    - `ws://example.com/socket?token=eyJhbGci...` is permanently stored in browser histories, web server access logs, and proxy logs.
  - **Recommended Handshake Auth Patterns**:
    1. **Short-Lived Ephemeral Ticket**: The client requests a 30-second single-use ticket via authenticated `POST /api/realtime/ticket`, then passes `ws://example.com/socket?ticket=xyz`.
    2. **HttpOnly SameSite Cookies**: Read cookies during the initial HTTP upgrade handshake.
    3. **Sec-WebSocket-Protocol**: Pass the bearer token via the `Sec-WebSocket-Protocol` header.
