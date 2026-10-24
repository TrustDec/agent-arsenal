---
description: Docker & container production invariants, multi-stage builds, rootless security, PID 1 signal traps, and layer optimization
globs: **/Dockerfile*,**/docker-compose*.{yml,yaml},**/.dockerignore,**/Containerfile*
alwaysApply: false
---

# Docker & Container Production Invariants

> Add these rules to your project if writing Dockerfiles, Containerfiles, or docker-compose manifests. Eliminate security risks, bloated image sizes, broken build caches, and zombie process leaks.

## 1. Multi-Stage Builds & Minimal Attack Surface
- **Strict Build/Runtime Separation**:
  - Always separate compilation tools (GCC, Rust compiler, Go toolchain, Node `devDependencies`, build headers) into a named build stage (`FROM node:22-alpine AS builder`).
  - Copy ONLY compiled artifacts or production dependencies into the final runtime image:
    ```dockerfile
    # Stage 1: Build
    FROM node:22-alpine AS builder
    WORKDIR /app
    COPY package.json pnpm-lock.yaml ./
    RUN corepack enable && pnpm install --frozen-lockfile
    COPY . .
    RUN pnpm build && pnpm prune --prod

    # Stage 2: Final Minimal Runtime
    FROM node:22-alpine AS runner
    WORKDIR /app
    COPY --from=builder /app/package.json ./
    COPY --from=builder /app/node_modules ./node_modules
    COPY --from=builder /app/dist ./dist
    ```
- **Hardened Base Images & Digest Pinning**:
  - Use minimal, hardened base distributions: Google `distroless` (`gcr.io/distroless/static-debian12`, `gcr.io/distroless/nodejs22-debian12`), `alpine`, or `-slim` Debian images.
  - ❌ **BAN `:latest` TAGS**: Always pin base images with specific semver tags and, in high-security environments, immutable SHA256 digests (`node:22.11.0-alpine3.20@sha256:...`).

## 2. Rootless Execution (Non-Root User Invariant)
- ❌ **NEVER RUN AS ROOT IN PRODUCTION**:
  - By default, Docker containers run as UID 0 (`root`). If compromised, a container breakout gives the attacker root privileges on the host kernel.
  - Explicitly create and switch to an unprivileged system user before executing the process:
    ```dockerfile
    # Alpine example
    RUN addgroup -S appgroup && adduser -S appuser -G appgroup
    USER appuser:appgroup
    ```
  - Ensure the non-root user has proper ownership of application directories and writable scratch paths:
    ```dockerfile
    RUN chown -R appuser:appgroup /app
    ```

## 3. PID 1, Signal Handling & Graceful Shutdown
- **Zombie Reaping & Signal Traps**:
  - In Linux containers, the entrypoint process runs as PID 1. Standard runtimes (like Node.js or Python) do not implement default init system behaviors (reaping orphaned zombie processes, forwarding `SIGTERM` signals).
  - Without proper signal forwarding, containers ignore Kubernetes or Docker stop signals and are abruptly killed via `SIGKILL` after the 10-second timeout, corrupting in-flight transactions.
- **Use an Init Process or Exec Form**:
  - Use lightweight init systems (`tini` or `dumb-init`):
    ```dockerfile
    RUN apk add --no-cache tini
    ENTRYPOINT ["/sbin/tini", "--"]
    CMD ["node", "dist/main.js"]
    ```
  - ❌ **Ban Shell Form**: Never write `CMD npm start` or `CMD python main.py` in shell form (which wraps the command in `/bin/sh -c` and blocks signals). ALWAYS use JSON array syntax: `CMD ["node", "dist/main.js"]`.

## 4. Secret Isolation & Build-Time Hygiene
- ❌ **BAN `ARG` AND `ENV` FOR SENSITIVE SECRETS**:
  - Values passed via `--build-arg` or stored in `ENV` are permanently baked into intermediate image layers and can be trivially extracted using `docker history --no-trunc` or inspecting image metadata.
  - Use BuildKit secret mounts for credentials needed only during image builds:
    ```dockerfile
    RUN --mount=type=secret,id=npmrc,target=/root/.npmrc pnpm install --frozen-lockfile
    RUN --mount=type=secret,id=github_token \
        GITHUB_TOKEN=$(cat /run/secrets/github_token) cargo fetch
    ```
- **Mandatory `.dockerignore`**:
  - Every project containing a Dockerfile MUST have a `.dockerignore` file.
  - Always exclude: `.git`, `.env*`, `node_modules`, `dist`, `build`, `target`, `coverage`, `*.log`, `.DS_Store`, `.cursor`, `.vscode`.

## 5. Layer Cache Optimization & Cleanups
- **Order by Volatility**:
  - Place slow-changing layers first (system libraries, dependency lockfiles), and fast-changing layers last (application code).
  ```dockerfile
  # 1. System packages
  RUN apk add --no-cache ca-certificates tzdata

  # 2. Dependency manifests (cached until dependencies change)
  COPY go.mod go.sum ./
  RUN go mod download

  # 3. Application code (changes frequently)
  COPY . .
  RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /bin/app ./cmd/server
  ```
- **Same-Layer Cleanup Invariant**:
  - Package manager caches must be cleared in the *same* `RUN` step where they are populated; otherwise, deleted files remain stored in the underlying layer:
    ```dockerfile
    RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
     && rm -rf /var/lib/apt/lists/*
    ```

## 6. Healthchecks & Resource Constraints
- **Explicit Container Healthcheck**:
  - Define deterministic health checks so orchestrators (Docker Compose, Swarm, Kubernetes) know when a container is genuinely ready to serve traffic:
    ```dockerfile
    HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
      CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
    ```
- **Docker Compose Production Hardening**:
  - Explicitly define resource constraints to prevent container memory leaks from crashing the host:
    ```yaml
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 1024M
        reservations:
          cpus: '0.5'
          memory: 256M
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /tmp
    ```
