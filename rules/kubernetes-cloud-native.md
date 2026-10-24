---
description: Kubernetes & cloud-native infrastructure production invariants, zero-downtime rolling updates, probe safety, and container security context hardening
globs: **/k8s/**/*.{yml,yaml},**/kubernetes/**/*.{yml,yaml},**/helm/**/*.{yml,yaml},**/templates/*.{yml,yaml},**/kustomization.{yml,yaml},**/charts/**
alwaysApply: false
---

# Kubernetes & Cloud-Native Production Invariants

> Add these rules to your project if writing Kubernetes manifests, Helm charts, Kustomize overlays, or GitOps pipelines (ArgoCD, Flux). Eliminate cascading crash loops, 502 downtime during deployments, silent CPU throttling, and privilege escalation vulnerabilities.

## 1. Health Probes: The Cascading Death Spiral Trap
- ❌ **ABSOLUTE BAN ON DOWNSTREAM DEPENDENCY CHECKS IN `livenessProbe`**:
  - Never check database connectivity, Redis caches, or external third-party microservices inside a `livenessProbe`.
  - **The Cascading Outage Failure Mode**: If your database experiences high latency or a brief network blip, every single pod replica running the service will fail its liveness probe simultaneously. Kubernetes will immediately kill and restart every pod in the cluster at the exact same moment. As hundreds of pods reboot and simultaneously reconnect, the resulting connection storm permanently takes down the database, converting a 10-second blip into an unrecoverable site-wide outage.
- **Strict Separation of Probe Semantics**:
  - **`startupProbe`**: Use for slow-starting runtimes (JVM cold starts, heavy AI model loading, cache warmups). Allocate generous failure thresholds:
    ```yaml
    startupProbe:
      httpGet:
        path: /livez
        port: 8080
      initialDelaySeconds: 10
      periodSeconds: 5
      failureThreshold: 30 # Allows up to 150s for initial boot
    ```
  - **`livenessProbe`**: Checks ONLY whether the local process is deadlocked or unrecoverably hung. If this probe fails, the pod is restarted:
    ```yaml
    livenessProbe:
      httpGet:
        path: /livez
        port: 8080
      periodSeconds: 10
      timeoutSeconds: 2
      failureThreshold: 3
    ```
  - **`readinessProbe`**: Checks if the container is currently capable of serving live network traffic. If this fails, Kubernetes removes the pod IP from the Service endpoints list without restarting the container:
    ```yaml
    readinessProbe:
      httpGet:
        path: /readyz
        port: 8080
      periodSeconds: 5
      timeoutSeconds: 2
      failureThreshold: 2
    ```

## 2. Zero-Downtime Deployments & Graceful Termination
- **The Ingress Routing Race Condition (502 Bad Gateway Trap)**:
  - When a pod termination begins, two asynchronous events occur concurrently:
    1. The `kube-apiserver` notifies endpoints controllers, kube-proxy, and ingress controllers (e.g., NGINX, Traefik, AWS ALB) to remove the pod IP from load balancer routing tables.
    2. The `kubelet` sends a `SIGTERM` signal to the container process.
  - Updating iptables / IPVS and syncing Ingress ingress routing rules across all cluster nodes takes between 2 to 7 seconds. If the application stops accepting connections immediately upon receiving `SIGTERM`, clients whose requests are routed in flight will receive `502 Bad Gateway` or `Connection Refused`.
- **The Mandatory `preStop` Sleep Invariant**:
  - Introduce an explicit `preStop` sleep hook to delay process shutdown until ingress routing tables completely remove the terminating pod from service:
    ```yaml
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 10"]
    ```
- **`terminationGracePeriodSeconds` Sizing**:
  - Ensure `terminationGracePeriodSeconds` is strictly greater than `preStop sleep` + `application in-flight request drain timeout`:
    ```yaml
    spec:
      terminationGracePeriodSeconds: 45
    ```
- **RollingUpdate Strategy & PodDisruptionBudget (PDB)**:
  - Never allow capacity dips during rolling updates. Always enforce `maxUnavailable: 0` (or `maxUnavailable: "0%"`) and `maxSurge: 25%`:
    ```yaml
    strategy:
      type: RollingUpdate
      rollingUpdate:
        maxSurge: 25%
        maxUnavailable: 0
    ```
  - Every production deployment MUST pair with a `PodDisruptionBudget` to protect against voluntary evictions (node drain, cluster autoscaling, kernel upgrades):
    ```yaml
    apiVersion: policy/v1
    kind: PodDisruptionBudget
    metadata:
      name: user-service-pdb
    spec:
      minAvailable: 1
      selector:
        matchLabels:
          app: user-service
    ```

## 3. Resource Allocation, QoS Classes & Throttling Immunity
- **Memory Invariant (Predictable Burstable or Guaranteed QoS)**:
  - For critical production workloads, set `requests.memory` equal to `limits.memory`.
  - When `limits.memory` exceeds `requests.memory`, the pod enters the lower-priority Burstable QoS tier. Under node memory pressure, the Linux kernel OOM-killer prioritizes killing pods whose memory usage exceeds their requested baseline.
  ```yaml
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2000m"
      memory: "1Gi" # Equal to request to prevent surprise OOMKill
  ```
- ⚠️ **The CPU Throttling Trap**:
  - Do NOT set tight CPU limits (`limits.cpu == requests.cpu`) unless in strict multi-tenant environments.
  - Linux CFS (Completely Fair Scheduler) quota enforces CPU limits on short 100ms periods. If a bursty thread uses 100ms of CPU in the first 20ms of a period, the kernel forcibly sleeps the thread for the remaining 80ms, generating artificial 80ms p99 latency spikes even when the host node has 60% idle CPU.
  - Set realistic `requests.cpu` to guarantee scheduling capacity, and omit or generously size `limits.cpu` to permit latency-free computational bursts.

## 4. Pod Security Standards (Restricted Profile)
- **Zero-Root Invariant & Root Filesystem Lock**:
  - Always enforce Pod Security Standard (PSS) `restricted` at the container and pod level:
    ```yaml
    securityContext:
      runAsNonRoot: true
      runAsUser: 10001
      runAsGroup: 10001
      fsGroup: 10001
      seccompProfile:
        type: RuntimeDefault
    ```
  - For containers, lock the root filesystem and strip all Linux capabilities:
    ```yaml
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
    ```
- **Writable Ephemeral Scratch Directory**:
  - When `readOnlyRootFilesystem: true` is enabled, applications that need scratch space (e.g., temporary file uploads, PID locks, cache) must mount an in-memory `emptyDir`:
    ```yaml
    volumeMounts:
      - name: tmp-volume
        mountPath: /tmp
    volumes:
      - name: tmp-volume
        emptyDir:
          medium: Memory
          sizeLimit: 128Mi
    ```

## 5. ConfigMaps, Secrets & Anti-Leak Discipline
- **Secret Volume Mounts Over Environment Variables**:
  - ❌ **AVOID dumping all secrets into container environment variables** via `envFrom: secretRef`:
    - Process environment variables are inherited by all child processes and visible in crash dumps, diagnostic endpoints, and `/proc/*/environ`.
  - Mount secrets as read-only files with restricted permissions:
    ```yaml
    volumeMounts:
      - name: db-secret-volume
        mountPath: /etc/secrets/database
        readOnly: true
    volumes:
      - name: db-secret-volume
        secret:
          secretName: db-credentials
          defaultMode: 0400
    ```
- **ConfigMap & Secret Immutability**:
  - For static configuration and credentials, set `immutable: true`. This prevents accidental drift, reduces kube-apiserver watch load, and significantly accelerates cluster scaling:
    ```yaml
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: app-config-v1
    immutable: true
    data:
      APP_ENV: "production"
    ```
- **Deterministic Helm Config Reloads**:
  - To automatically trigger a rolling update when a ConfigMap or Secret changes in Helm, compute its SHA256 checksum in pod annotations:
    ```yaml
    metadata:
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    ```

## 6. NetworkPolicy & Least-Privilege Isolation
- **Default-Deny Ingress and Egress**:
  - Every namespace must start with a default-deny policy to block unauthorized lateral movement between compromised pods:
    ```yaml
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: default-deny-all
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
        - Egress
    ```
- **Explicit DNS & Ingress Whitelisting**:
  - When egress is locked down, pods cannot resolve domain names unless explicitly permitted to reach CoreDNS:
    ```yaml
    egress:
      - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
        ports:
          - protocol: UDP
            port: 53
          - protocol: TCP
            port: 53
    ```
