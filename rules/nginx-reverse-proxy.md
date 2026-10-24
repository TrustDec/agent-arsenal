---
description: NGINX, reverse proxy, ingress gateway, and web server production invariants, WebSocket upgrades, keepalive connection pooling, dynamic DNS resolution, rate limiting, and security hardening
globs: **/nginx/**,**/nginx.conf,**/conf.d/**,**/sites-available/**,**/sites-enabled/**,**/ingress/**,**/traefik/**,**/Caddyfile,**/*.caddy,**/reverse-proxy/**
alwaysApply: false
---

# NGINX, Reverse Proxies & Ingress Gateway Invariants (NGINX, OpenResty, Caddy & Traefik)

> Add these rules to your project if configuring NGINX, OpenResty, ingress controllers, API gateways, load balancers, or edge reverse proxies for microservices, Single-Page Applications (SPAs), WebSockets, or streaming backends.

---

## 1. Off-by-Slash Path Traversal & `proxy_pass` URI Rewriting Traps
Improper trailing slashes in NGINX configuration cause either dangerous directory traversal vulnerabilities or silent, broken upstream URI stripping.

- ❌ **THE OFF-BY-SLASH ALIAS PATH TRAVERSAL VULNERABILITY**:
  - Missing the trailing slash on a `location` directive when using `alias` allows path traversal:
    ```nginx
    # CATASTROPHIC SECURITY HOLE:
    location /static {
        alias /var/www/static/;
    }
    ```
  - An attacker requesting `/static../app_config.json` causes NGINX to resolve `/var/www/static/../app_config.json`, exposing sensitive files outside the intended directory.
  - ✅ **Production Alias Invariant**: Both the `location` path and the `alias` target MUST end with a trailing slash:
    ```nginx
    location /static/ {
        alias /var/www/static/;
    }
    ```

- ❌ **THE `proxy_pass` TRAILING SLASH REWRITE TRAP**:
  - In NGINX, adding a trailing slash or URI to `proxy_pass` instructs NGINX to strip the matched location prefix and replace it with the URI. Omitting it preserves the original request URI untouched.
  - **Case A: Transparent Forwarding (No rewrite)**:
    ```nginx
    # Request to /api/v1/users is forwarded as /api/v1/users to backend
    location /api/ {
        proxy_pass http://backend_upstream;
    }
    ```
  - **Case B: Prefix Stripping (URI rewriting)**:
    ```nginx
    # Request to /api/v1/users is forwarded as /v1/users to backend
    location /api/ {
        proxy_pass http://backend_upstream/;
    }
    ```
  - ❌ **NEVER mix regex locations with `proxy_pass` URIs**:
    - NGINX syntax forbids URI paths in `proxy_pass` inside regex locations (`location ~ ^/api/(.*)`). Use `rewrite ... break;` explicitly if modifying regex paths before passing upstream.

---

## 2. Upstream Keepalive & TCP Socket Exhaustion Defense
By default, NGINX uses HTTP/1.0 without keepalive connections when talking to upstreams. Every client request triggers a new TCP handshake (SYN/ACK) and teardown (FIN/ACK) to the upstream backend.

- ❌ **THE `TIME_WAIT` SOCKET EXHAUSTION DISASTER**:
  - Under moderate to high concurrency, hundreds of new sockets enter `TIME_WAIT` status every second. Ephemeral port exhaustion occurs rapidly, returning `bind() failed (98: Address already in use)` or HTTP 502 Bad Gateway to clients.
- ✅ **The Upstream Keepalive Invariant**:
  - In the `upstream` block, allocate a keepalive idle connection cache.
  - In the `location` or `http` block, force HTTP/1.1 and clear the `Connection` header (which defaults to `close` in HTTP/1.0 mode):
    ```nginx
    upstream backend_nodes {
        server 10.0.1.10:8080 max_fails=3 fail_timeout=10s;
        server 10.0.1.11:8080 max_fails=3 fail_timeout=10s;

        # Keep alive up to 64 idle connections per worker process:
        keepalive 64;
        keepalive_requests 10000;
        keepalive_timeout 60s;
    }

    server {
        listen 443 ssl http2;
        server_name api.example.com;

        location / {
            proxy_pass http://backend_nodes;

            # Mandatory keepalive headers:
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            
            # Standard forwarded identity headers:
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
    ```

---

## 3. Dynamic DNS Resolution in Cloud & Containerized Environments
NGINX resolves domain names specified in static `proxy_pass http://service.internal;` directives only once during startup or reload.

- ❌ **THE STALE IP / CRASHING STARTUP TRAP**:
  - In Kubernetes, AWS ECS, Docker Swarm, or autoscaling groups, pod or container IPs change continuously. Once an old pod terminates, NGINX keeps routing traffic to the stale IP, triggering continuous HTTP 502 errors until NGINX is manually reloaded.
  - If the upstream domain name is unavailable when NGINX boots, NGINX fails to start completely (`host not found in upstream`).
- ✅ **The Dynamic Variable Resolver Invariant**:
  - Assign the upstream endpoint to a runtime NGINX variable (`$upstream_endpoint`) and configure an explicit `resolver` directive with a TTL:
    ```nginx
    # In Docker use 127.0.0.11; in Kubernetes use kube-dns (e.g. 10.96.0.10 or 169.254.20.10 on AWS ECS)
    resolver 127.0.0.11 valid=10s ipv6=off;
    resolver_timeout 5s;

    server {
        listen 80;
        server_name internal-gateway.local;

        location /service-a/ {
            # Storing endpoint in a variable forces dynamic re-resolution per 'valid' interval:
            set $service_a_upstream http://service-a.default.svc.cluster.local:8080;
            rewrite ^/service-a/(.*) /$1 break;
            proxy_pass $service_a_upstream;

            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
        }
    }
    ```

---

## 4. WebSocket & Server-Sent Events (SSE) Streaming Invariants
WebSockets require explicit HTTP hop-by-hop upgrade headers, while LLM / AI token streaming (SSE) requires unbuffered downstream transmission.

- ❌ **THE STATIC CONNECTION "UPGRADE" TRAP**:
  - Hardcoding `proxy_set_header Connection "upgrade";` unconditionally breaks normal HTTP requests that do not send an `Upgrade` header.
- ✅ **The Dynamic Connection Upgrade `map` Invariant**:
  - Define a dynamic mapping in the `http` context:
    ```nginx
    http {
        # Dynamically set Connection to 'upgrade' if Upgrade header exists, else 'close'
        map $http_upgrade $connection_upgrade {
            default upgrade;
            ''      close;
        }

        server {
            listen 443 ssl http2;
            server_name ws.example.com;

            location /ws/ {
                proxy_pass http://websocket_backend;

                proxy_http_version 1.1;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection $connection_upgrade;

                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

                # WebSockets require extended timeouts to prevent premature teardown:
                proxy_read_timeout 3600s;
                proxy_send_timeout 3600s;
            }
        }
    }
    ```
- **Server-Sent Events (SSE) & LLM Stream Invariants**:
  - When streaming AI tokens or real-time event feeds, proxy buffering stores partial tokens in memory chunks, causing tokens to stall and deliver in jerky bursts instead of smooth characters.
  - Disable proxy buffering and response caching for SSE routes:
    ```nginx
    location /api/ai/stream/ {
        proxy_pass http://llm_backend;

        proxy_http_version 1.1;
        proxy_set_header Connection "";

        # Crucial: disable proxy buffering for immediate token transmission:
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;

        # Prevent premature timeout during long LLM thinking phases:
        proxy_read_timeout 600s;
    }
    ```

---

## 5. Client Real IP Restoration & Anti-Spoofing Defense
When behind Cloudflare, AWS ALB, Fastly, or corporate ingress proxies, `$remote_addr` contains the IP of the proxy load balancer, not the genuine client.

- ❌ **THE `X-Forwarded-For` SPOOFING VULNERABILITY**:
  - Trusting an arbitrary `X-Forwarded-For` header sent directly by an untrusted client lets attackers spoof any IP address, completely bypassing IP whitelists and rate limits.
- ✅ **The Real IP Module Invariant**:
  - Use `ngx_http_realip_module` to trust only verified proxy CIDRs, and set `real_ip_recursive on` to traverse multiple trusted proxy hops backwards to find the genuine client IP:
    ```nginx
    # Trust only known proxy CIDRs (e.g., Cloudflare IP ranges or internal VPC ALB):
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;
    # Cloudflare IPv4 examples:
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 103.21.244.0/22;

    real_ip_header CF-Connecting-IP; # or X-Forwarded-For
    real_ip_recursive on;
    ```
  - Now, `$remote_addr` is guaranteed to contain the authentic client IP, making rate limiting and geolocation secure.

---

## 6. Buffer Sizing, Disk Spill Prevention & Payload Ceilings
Misconfigured proxy buffers force NGINX to write backend responses to disk or cause client uploads to crash with HTTP 413.

- ❌ **THE "AN UPSTREAM RESPONSE IS BEING BUFFERED TO A TEMPORARY FILE" WARNING**:
  - When backend API responses exceed NGINX's in-memory proxy buffers, NGINX writes the payload to `/var/cache/nginx/proxy_temp/`. On busy servers, this causes massive disk I/O thrashing and high response latency.
- ✅ **Optimized In-Memory Proxy Buffer Invariants**:
  ```nginx
  http {
      # Initial buffer for response headers from upstream:
      proxy_buffer_size 16k;

      # Number and size of buffers for response bodies per connection:
      proxy_buffers 8 32k; # 256KB total in-memory buffer

      # Maximum size of buffers that can be busy sending to client:
      proxy_busy_buffers_size 64k;

      # Maximum size of files written to disk if response exceeds buffers:
      proxy_max_temp_file_size 1024m;
  }
  ```
- **Client Body Payload Ceilings (`client_max_body_size`)**:
  - NGINX defaults `client_max_body_size` to `1m`. File uploads larger than 1MB fail with `413 Request Entity Too Large`.
  - ❌ Never set `client_max_body_size 0;` globally (removes all upload limits, exposing server to disk filling OOM attacks).
  - Scope large payload limits strictly to file upload endpoints:
    ```nginx
    server {
        # Default strict 2MB ceiling across all general endpoints:
        client_max_body_size 2M;

        location /api/v1/files/upload {
            # Isolated 50MB ceiling specifically for media uploads:
            client_max_body_size 50M;
            proxy_pass http://upload_service;
        }
    }
    ```

---

## 7. Production Rate Limiting & Burst Protection
Rate limiting prevents abusive scraping and denial-of-service without penalizing legitimate bursty user navigation.

- ❌ **THE NAIVE RATE LIMITING LATENCY SPIKE**:
  - `limit_req zone=api rate=10r/s;` without `burst` and `nodelay` drops any request exceeding 1 per 100 milliseconds, instantly failing normal web pages loading 15 simultaneous CSS/JS assets.
- ✅ **The Binary Remote Address & Burst Invariant**:
  - Store keys using `$binary_remote_addr` (consumes only 4 bytes per IPv4 or 16 bytes per IPv6 address, vs ~32-64 bytes for `$remote_addr` text), allowing a 10MB zone to track ~160,000 concurrent IPs:
    ```nginx
    http {
        # 10MB zone tracks ~160k active IPs; allows average 20 req/s:
        limit_req_zone $binary_remote_addr zone=api_general:10m rate=20r/s;
        limit_req_zone $binary_remote_addr zone=login_strict:10m rate=2r/s;

        # Return RFC 6585 HTTP 429 Too Many Requests instead of default 503 Service Unavailable:
        limit_req_status 429;

        server {
            listen 443 ssl http2;
            server_name api.example.com;

            # General API: Allow short bursts up to 30 requests processed without artificial delay:
            location /api/ {
                limit_req zone=api_general burst=30 nodelay;
                proxy_pass http://backend_api;
            }

            # Sensitive auth routes: Strict limit with burst=5:
            location /api/v1/auth/login {
                limit_req zone=login_strict burst=5 nodelay;
                proxy_pass http://backend_api;
            }
        }
    }
    ```

---

## 8. TLS/SSL Hardening & Modern Security Headers
Never expose outdated cryptographic protocols or leak internal server architecture signatures.

- ❌ **TOTAL BAN ON SSLv3, TLS 1.0, AND TLS 1.1**:
  - TLS 1.0 and 1.1 suffer from known cryptographic vulnerabilities (POODLE, BEAST). Modern production environments mandate TLS 1.2 and TLS 1.3 exclusively.
- ✅ **Production TLS & Security Invariant**:
  ```nginx
  server {
      listen 443 ssl http2;
      server_name example.com;

      # Certificates:
      ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
      ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

      # Restrict protocols to modern standards:
      ssl_protocols TLSv1.2 TLSv1.3;
      ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
      ssl_prefer_server_ciphers off;

      # Session Caching (shared 10MB cache stores ~40,000 sessions):
      ssl_session_cache shared:SSL:10m;
      ssl_session_timeout 1d;
      ssl_session_tickets off;

      # OCSP Stapling (accelerates client TLS handshake):
      ssl_stapling on;
      ssl_stapling_verify on;
      resolver 1.1.1.1 8.8.8.8 valid=300s;
      resolver_timeout 5s;

      # Security Headers (always flag ensures header is sent on error responses too):
      add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-Frame-Options "DENY" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;
      add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

      # Hide NGINX version string from response Server header:
      server_tokens off;
  }
  ```

---

## 9. Zero-Downtime Reloads & Configuration Validation
Never execute `systemctl restart nginx` in production environments.

- ❌ **THE UNVALIDATED RESTART TRAP**:
  - Running `systemctl restart nginx` immediately terminates existing worker processes, abruptly severing active long-polling requests, WebSocket connections, and client file uploads.
  - If the new configuration file contains a syntax typo, NGINX fails to start, resulting in total immediate service downtime.
- ✅ **The Atomic Test-and-Reload Protocol**:
  - Always validate configuration syntax before signaling the master process:
    ```bash
    # 1. Test syntax and verify all certificate paths exist:
    nginx -t

    # 2. If exit code is 0, issue graceful reload (master spawns new workers with new config, old workers gracefully finish in-flight requests):
    nginx -s reload
    ```
  - In Docker or Kubernetes container workflows:
    ```bash
    docker exec ingress-nginx nginx -t && docker exec ingress-nginx nginx -s reload
    ```

---

## 10. SPA Routing & Fallback Safety (Single-Page Apps)
When serving modern React, Vue, Svelte, or Angular client-side applications:

- ❌ **THE DIRECT ASSET 404 TRAP**:
  - Using a naive `try_files $uri /index.html;` causes missing `.js`, `.css`, or image assets to return HTTP 200 with the `index.html` content instead of a proper HTTP 404, causing bizarre JavaScript syntax errors (`Uncaught SyntaxError: Unexpected token '<'`).
- ✅ **The Segregated Static Assets & SPA Fallback Invariant**:
  ```nginx
  server {
      listen 80;
      server_name app.example.com;
      root /usr/share/nginx/html;
      index index.html;

      # Static assets with content-hash: cache immutably for 1 year
      location /assets/ {
          expires 1y;
          add_header Cache-Control "public, no-transform, immutable";
          try_files $uri =404;
      }

      # HTML index: MUST NEVER be cached aggressively so new deployments are seen immediately
      location / {
          expires -1;
          add_header Cache-Control "no-store, no-cache, must-revalidate";
          try_files $uri $uri/ /index.html;
      }
  }
  ```
