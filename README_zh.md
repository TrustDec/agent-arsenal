# Agent Arsenal 🛡️🎨

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/TrustDec/agent-arsenal.svg?style=social)](https://github.com/TrustDec/agent-arsenal)
[![兼容生态](https://img.shields.io/badge/兼容生态-Claude%20Code%20%7C%20Cursor%20%7C%20Windsurf%20%7C%20Copilot%20%7C%20Cline%20%7C%20Pi-emerald.svg)]()

**专为 Coding Agents 打造的工业级工程防暴走规范与审美设计系统。**  
*一秒终结 AI 瞎改文件、虚假修复、以及高饱和土味渐变 UI。*

[English](README.md) | [简体中文](README_zh.md)

</div>

---

## ⚡ 效果对比（Before vs After）

| 默认 AI 生成状态（AI 糊弄） | 注入 Agent Arsenal 之后 |
| :--- | :--- |
| ❌ 高饱和刺眼紫蓝渐变背景卡片 | ✅ 纯正深 Zinc/Slate 优雅中性色 + 1px 精致微边框 |
| ❌ 臃肿滑稽的 `rounded-3xl` 大圆角堆叠 | ✅ 严苛 8pt 网格对齐、光学字偶距微调与 Geist/SF Pro 现代排版 |
| ❌ 满屏 `Lorem Ipsum` 和假数据 | ✅ 贴合真实生产业务的数据语义、按压微交互与可访问性焦点环 |
| ❌ 修 2 行 bug 造成 200 行污染 Diff | ✅ 外科手术式修改，无辜代码行 0 变动 |
| ❌ 遇到报错无脑用 `unwrap()` 或 `@ts-ignore` 掩盖 | ✅ 机器真实验证（编译/测试），根因排查彻底修复 |

---

## ✨ 垂直技术栈专属严苛规范

除了通用的防幻觉规则外，现已全面补充主流技术栈与现代协议规范：

- ⚡ **边缘计算、Cloudflare Workers 与 Serverless 运行时规范 (`rules/edge-serverless-workers.md`)**：基于轻量级 V8 Isolate 隔离执行模型与绝对严禁模块级可变全局状态（根除多租户同一 Isolate 跨请求数据严重串扰与越权漏洞）、请求后异步生命周期强制 `ctx.waitUntil(promise)` 守护（防止响应发送后未决 Promise 遭底层直接就地掐死）、零 C++ 原生模块之 WinterCG 标准边界强制约束、基于 Cloudflare Hyperdrive 与 Serverless HTTP 驱动彻底根绝边缘实例并发瞬间打爆数据库最大连接数（`max_connections`）、Durable Objects 单线程强一致 Actor 模型与多键原子存储事务（`storage.transaction()`）、零成本 WebSocket 睡眠唤醒机制（WebSocket Hibernation API `ctx.acceptWebSocket()`）、存储选型边界法则（Workers KV 弱一致只读缓存 vs D1 边缘关系型 SQLite vs R2 零流出费流式对象存储）、128MB 内存上限之纯流式处理管道（`ReadableStream` / `TransformStream`）、50 次子请求上限削峰控制、Smart Placement 智能调度消灭跨大洲网络 RTT 延迟税，以及 Wrangler 加密密钥管理。
- ⚙️ **分布式后台任务、队列与持久化工作流规范 (`rules/background-jobs-workflows.md`)**：分布式队列系统（Redis, SQS, RabbitMQ）至少投递一次（At-Least-Once）现实与消费者强制幂等性规范、任务 Payload 极简化准则（只传不可变 ID，绝对严禁序列化整张数据库实体）、全抖动指数退避根治下游重试风暴、有界重试次数与死信队列（DLQ）毒丸消息隔离、Temporal / Cadence / Inngest 持久化工作流确定性法则（严禁在工作流内执行 `time.Now()`、`Math.random()`、网络 I/O 或原生 Goroutine，非确定性操作全部下沉至 Activities/Steps）、Worker 容器优雅停机（`SIGTERM` 停收新任务并排空 In-flight 任务）、心跳守护与僵尸任务复活、多租户公平队列防大户饥饿，以及长耗时批处理断点 Checkpoint 记录与分布式 Saga 逆向补偿。
- 🧠 **Agent 上下文工程、KV Cache 缓存优化与记忆体系 (`rules/context-memory-engineering.md`)**：针对 Claude 3.5/3.7、GPT-4o、Gemini 等前沿模型强制 Prompt 前缀（Prefix）KV 缓存确定性（严禁在前缀插入动态时间戳或波动态指标，达成 10 倍延迟降级与 75-90% 成本削减）、三层渐进式渐次暴露法则（AST 符号/路径检索 -> 按行切片只读审查 -> 彻底重构才允许读取整文件）、持久化记忆库协议（`ACTIVE_CONTEXT.md` / `SYSTEM_PATTERNS.md` 跨会话防失忆）、Sub-agent 隔离与 5 行密集结构化摘要交接（根除单体 Agent 上下文污染与“迷失于中间”衰减）、严格 XML 语义边界隔离（`<file_content>`, `<tool_output>` 防间接提示词注入劫持），以及连续 3 次调试失败强制熔断回滚机制。
- 🔐 **身份认证、OAuth 2.1 与 Token 生产级安全守则 (`rules/auth-identity.md`)**：全面严禁使用 `localStorage`/`sessionStorage` 存放敏感鉴权 Token（彻底杜绝 XSS 凭证外泄劫持）、强制 `__Host-` 前缀 / `HttpOnly` / `SameSite=Lax/Strict` 加固 Cookie 规范、JWT 算法硬编码白名单锁定（彻底根绝 `alg: "none"` 与 RS256/HS256 公钥混淆伪造攻击）、基于 Token Family 的单次刷新令牌轮转（RTR）与重放攻击自动熔断作废整组会话、OAuth 2.1 全面强制 PKCE（`S256` 算法）、CSRF `state` 与 OIDC `nonce` 强校验、严禁重定向 URI 通配符（强制全路径严格匹配）、越权访问（BOLA/IDOR）多租户强制数据作用域（`WHERE tenant_id`）约束，以及 WebAuthn/Passkey 单调递增签名计数器克隆检测。
- 🧪 **测试工程规范与反脆弱验证守则 (`rules/testing-discipline.md`)**：全面严禁硬编码 `sleep` 随缘等待（强制条件轮询与 Fake Timers 虚拟时间推进）、基于事务 Rollback 与独立数据库实例根治测试状态互相污染、坚决打击“给 Mock 写测试”的伪测试反模式、强制核心业务配备表驱动测试（Table-Driven）与边界极限值矩阵覆盖、严禁未 `await` 的浮动异步断言，以及多协程/线程竞争检测（`-race`）。
- 🚀 **CI/CD 自动化与 GitHub Actions 安全守则 (`rules/cicd-github-actions.md`)**：第三方 Actions 强制 40 位完整 SHA Hash 锁定（防语义化版本标签篡改发动供应链投毒）、全面根除 Bash 行内直接插值 `${{ github.event... }}` 导致的远程命令注入重大漏洞、强制顶层 `permissions: contents: read` 最小权限原则、严防 `pull_request_target` 触发器下检出不可信 Fork PR 代码导致仓库密钥泄露的著名安全陷阱，以及全链路 OIDC 短期凭证置换。
- 🌐 **高可用 API 设计与分布式系统规范 (`rules/api-distributed-systems.md`)**：强制状态变更接口幂等性规范（`Idempotency-Key` 原子预占与 SHA-256 请求体哈希校验防篡改）、全抖动指数退避根绝重试风暴（Thundering Herd）、熔断器状态机（Closed/Open/Half-Open 探针机制）、W3C `traceparent` 与 OpenTelemetry 分布式链路追踪透传、基于事务性发件箱（Transactional Outbox）根除双写数据不一致灾难、RFC 7807 Problem Details 统一错误响应，以及分布式滑动窗口限流与优雅过载保护。
- 🧠 **AI、LLM 应用与 RAG 检索增强生产级规范 (`rules/ai-llm-rag.md`)**：强制原生 Structured Outputs / JSON Schema 结构化提取与单轮自愈机制、严禁无脑固定字符切割（强制 Markdown/AST 语义边界切分）、混合检索（向量密集检索 + BM25 稀疏词法检索经 RRF 融合）、Cross-Encoder 精准重排、RAG 注入隔离边界（XML 显式防间接提示词注入）、严格 Token 窗口预算、全抖动指数退避抗 429 限流与 SSE 流式连接断开即时中止上游。
- 🛡️ **应用安全与 OWASP 防御规范 (`rules/security-appsec.md`)**：严打 Agent 随手写出的 SSRF 漏洞（强制 DNS 预解析与内网私有 IP/云元数据 169.254 封禁）、命令拼接与 Shell 注入绝对防御、SQL 参数化与动态列白名单校验、路径遍历根目录规范校验、密码/签名常量时间比较（`timingSafeEqual` 防时序侧信道攻击）、CSPRNG 密码学安全随机数与 ReDoS 正则灾难性回溯免疫。
- 🐳 **Docker 与容器化生产级规范 (`rules/docker-containers.md`)**：强制多阶段构建（Multi-Stage）收敛攻击面（`distroless`/`alpine`）、生产环境严禁 root 用户运行（`USER nonroot`）、PID 1 信号转发与轻量 Init（`tini`/Exec 格式）杜绝优雅关机超时死进程、BuildKit Secret 挂载防密钥硬编码至镜像层、同层包管理器缓存清理与真实健康检查。
- ☸️ **Kubernetes 与云原生生产级规范 (`rules/kubernetes-cloud-native.md`)**：全面严禁在 `livenessProbe` 中探测数据库等外部依赖（根除依赖抖动诱发全集群 Pod 连环重启雪崩）、强制注入 `preStop` 延时睡眠解决滚动发布期间 502 Bad Gateway 路由不同步瞬断陷阱、Pod 安全准则 PSS restricted 加固（无 root 运行、根文件系统只读、Drop 全部 Linux Capabilities）、ConfigMap/Secret 标记 `immutable: true` 减轻 API Server 负载、Secret 采用只读 Volume 挂载防环境变量泄露，以及强制配置 PodDisruptionBudget (PDB) 护航集群调度。
- 🏗️ **Terraform 与基础设施即代码 (IaC) 生产级规范 (`rules/terraform-iac.md`)**：远程 Backend 状态文件强加密与 DynamoDB 原子分布式状态锁、有状态核心资源强制 `lifecycle { prevent_destroy = true }` 避免误删毁灭性灾难、热更资源 `create_before_destroy = true` 规避下线瞬断窗口、IAM 策略严禁通配符（`Action: "*"` 与 `Resource: "*"` 绝对红线）、非公开端口严禁 `0.0.0.0/0` 全网暴露、S3 存储桶强制开启四项防公开访问保护与 KMS 桶密钥加密、敏感变量声明 `sensitive = true` 杜绝日志脱敏穿透，以及悲观提供商版本锁定 (`~> 5.40`) 与入参 `validation` 强校验。
- 🔌 **Model Context Protocol (MCP) 服务端与工具规范 (`rules/mcp-server.md`)**：全面严禁 stdio 传输下的 `stdout` 杂质输出（`console.log` / `print` 会彻底打崩 JSON-RPC 字节流致客户端断联）、工具入参强制配备详尽 Schema `description` 引导 Agent 决策、严格上限控制与分页防 Context 爆炸、错误统一走 `{ isError: true }` 优雅降级，以及路径遍历白名单与 Shell 注入绝对防御。
- 🔷 **TypeScript 与 Node.js/Bun 生产级规范 (`rules/typescript.md`)**：全面严禁 `any` 与未经校验的暴力断言（`as T`）、I/O 边界强制使用 Zod/运行时 Schema 校验、根绝浮动 Promise（Floating Promise）、严禁非空断言感叹号（`!`）、强制可辨识联合类型（Discriminated Unions）消除不可能状态、防范 Node/Bun 事件监听器泄露与无上限 Map 内存暴涨。
- 🐹 **Golang 并发与系统工程 (`rules/golang.md`)**：强制 `context.Context` 规范传递、`errgroup` 协同工作与严防 Goroutine 泄露、切片子切片内存截留排查、测试必带 `go test -race`、HTTP 响应体关闭前 Drain 排水排查、错误使用 `%w` 与 `errors.Is/As` 保持因果链、生产代码零 panic 与优雅停机、容器环境配置 `GOMEMLIMIT` 与 `GOGC` 步调规避 cgroup OOM Kill 崩溃、64 位结构体字段降序内存对齐（节约 20-40% 内存空间）、Go 1.21+ `sync.OnceFunc` 懒加载单例、后台 Goroutine 必须配备 `defer recover()` 恐慌防线、切片与 Map 容量预分配（`make(..., cap)`）、Go 1.21+ `log/slog` 强类型属性（零反射分配）、有类型 nil 指针转接口判空陷阱规避、`singleflight.Group` 击穿合并抑制、`ctx.Err()` 批处理循环即时中止检查、非公开内部 `pprof` 端口安全防线、`sync.Pool` 内存截留排查与容量上限熔断、通道方向强类型化与单所有者安全关闭原则、禁止 Mutex 值传递拷贝，以及基于 `atomic.Pointer[T]` 的无锁并发热更。
- 🗄️ **SQL 与数据库生产级安全 (`rules/database-sql.md`)**：严守 Expand & Contract 零停机迁移法、生产接口严禁 `SELECT *`、复合索引最左前缀原则、软删除部分索引（Partial Index）、PostgreSQL 并发建索引、SQL 参数化防注入、超短事务与严禁事务内发起网络 I/O、PgBouncer 事务连接池模式安全禁令（禁会话级状态与强制 `pg_advisory_xact_lock`）、JSONB GIN `jsonb_path_ops` 与表达式索引选型、PostgreSQL 事务 ID (XID) 回卷 Autovacuum 防线、海量数据表声明式 Range 分区瞬间清理、PostgreSQL 覆盖索引（`INCLUDE`）纯索引扫描、时序递增 UUIDv7 替代随机 UUIDv4 根除 B-Tree 页分裂与缓存震荡、强制外键列建索引、DDL 强制包裹 `lock_timeout` 与 `statement_timeout` 规避排它锁堆死连接池、连接池容量利特尔法则（Little's Law）科学定容、读-改-写并发丢失更新（Lost Updates）防线（原子算术、行锁与 OCC 乐观锁）、高频队列状态表部分索引（Partial Index），以及多列相关性统计信息（`CREATE STATISTICS`）。
- ⚡ **Redis 与高并发缓存生产级规范 (`rules/redis-caching.md`)**：全面严禁生产环境执行 `KEYS *` 阻塞主事件循环（强制游标式 `SCAN`/`SSCAN` 分批）、大键异步内存释放（`UNLINK` 替代阻塞式 `DEL`）、基于 Singleflight 与 XFetch 概率性提前过期根治缓存击穿（Stampede）、强制 TTL 动态抖动（Jitter）消灭缓存雪崩、防范缓存穿透（空值短期缓存与 Bloom Filter）、原子令牌校验 Lua 脚本安全释放分布式锁、基于有序集合（ZSET）的滑动窗口限流器，以及 Cache-Aside 事务提交后失效（Delete over Update）一致性原则。
- 📨 **Apache Kafka 与事件流生产级架构规范 (`rules/kafka-event-streaming.md`)**：强制开启幂等生产者（`enable.idempotence=true`）、严守 `acks=all` 与 `min.insync.replicas=2` 绝对防丢数据契约、分区键散列设计消灭倾斜热点分区、消费者 Poll 循环心跳守护（严防处理耗时超标 `max.poll.interval.ms` 触发再平衡雪崩）、全面严禁自动提交 Offset（`enable.auto.commit=false` 根除停机丢消息）、采用 `CooperativeStickyAssignor` 根治“全局停顿”再平衡风暴、三层非阻塞重试与死信队列（DLT）拓扑、Schema Registry 兼容性演进准则（BACKWARD/FULL），以及基于 `wakeup()` 与 Flush 的优雅停机闭环。
- 📊 **可观测性、OpenTelemetry 与生产遥测规范 (`rules/observability-telemetry.md`)**：全面严禁生产代码裸写 Print（强制结构化 JSON 日志）、敏感数据脱敏防线（请求头/密码/Token/卡号自动过滤）、Prometheus 标签基数爆炸防御（绝对严禁将 user_id/order_id/动态路径放入 metric labels 炸毁 TSDB）、Counter/Gauge/Histogram 四大黄金信号指标语义、跨进程/跨网络 W3C `traceparent` 链路上下文透传、OpenTelemetry Span 完整生命周期闭环与显式错误状态标记（`StatusCode.ERROR`），以及存活/就绪探针解耦（`/livez` 绝不探测外部数据库）。
- ⚡ **gRPC 与 Protocol Buffers 生产级规范 (`rules/grpc-protobuf.md`)**：二进制协议兼容性绝对保障、字段编号（Tag）一旦发布终生不可篡改复用、字段废弃强制 `reserved` 标记锁定、枚举项首位强制 `ENUM_TYPE_UNSPECIFIED = 0` 根除默认值语义伪造、proto3 `optional` 显式判空防踩坑、W3C `grpc-timeout` 超时截止时间链路逐级透传、标准 gRPC 状态码规范映射（`codes.InvalidArgument`/`codes.NotFound`/`codes.FailedPrecondition`）、基于 `google.rpc.Status` 与 `BadRequest.FieldViolation` 的强类型富错误模型、流式 RPC 队列背压与客户端断连即时退出、单例 `ClientConn` 连接复用、NAT/负载均衡长连接心跳保活与防刷屏配置（`KeepaliveEnforcementPolicy`），以及拦截器分层编排（Recovery 居首）。
- 📡 **WebSockets、Server-Sent Events (SSE) 与实时流通信规范 (`rules/websockets-realtime.md`)**：协议选型架构矩阵（LLM Token 流与通知首选 SSE，双向交互/协同画布选用 WebSocket）、全面严禁客户端高频短轮询、原生 Ping/Pong 控制帧心跳守护与僵尸连接剔除、全抖动（Full Jitter）指数退避彻底免疫重连风暴、单调递增消息 ID 与服务端环形重放缓冲区保障断网重连无损补发、严格有界出站队列与慢消费者淘汰机制（防服务端堆积 OOM）、基于分布式 Pub/Sub（Redis Streams/NATS）跨节点多 Pod 扇出、滚动发布发送 WebSocket `1001 (Going Away)` 优雅断链避震，以及跨站 WebSocket 劫持（CSWSH）`Origin` 严格白名单校验。
- ⚡ **Web 性能、Core Web Vitals 与浏览器运行时规范 (`rules/web-performance-vitals.md`)**：严禁在 UI 事件监听器中执行 >50ms 长任务（保障 Interaction to Next Paint / INP < 200ms）、基于 `scheduler.yield()` 与宏任务向浏览器渲染管道让出主线程控制权、强制读写分批执行（`requestAnimationFrame`）彻底根除布局抖动与强制同步回流（Layout Thrashing）、Cumulative Layout Shift (CLS < 0.1) 强防线（多媒体强制尺寸/比例占位与字体度量修正 `size-adjust` 消除 FOUT 偏移）、Largest Contentful Paint (LCP < 2.5s) 首屏大图优先级（`fetchpriority="high"` 与 `loading="eager"` 严禁懒加载）、DOM 树节点预算上限（<1,500 节点）与超长列表虚拟化（Virtualization）、重型三方库动态代码分割（Code Splitting），以及游离 DOM 内存泄漏排查。
- 💚 **Vue 3 与 Nuxt 3 响应式与 SSR 严苛守则 (`rules/vue-nuxt.md`)**：强制 `<script setup lang="ts">`、适配 Vue 3.5+ 响应式 Props 解构与 `useTemplateRef()`、使用 `onWatcherCleanup()` 规范清理、严禁覆写 `reactive()` 对象引用、绝对严禁在 Nuxt SSR 模块作用域声明可变状态（根治多租户跨请求数据串扰重大漏洞）、Nitro 服务端接口强制 `readValidatedBody` 运行时校验、Pinia 状态解构必配 `storeToRefs` 与生命周期副作用必须卸载、无障碍交互与键盘焦点管理/焦点捕获（Radix Vue）、Teleport 客户端挂载防御、Nuxt 媒体尺寸优化与 GPU 硬件加速过渡、带回滚机制的乐观 UI 更新、长列表 `shallowRef` 性能防御、`useAsyncData` 参数化唯一缓存键去重，以及自定义指令事件监听器卸载。
- 🧡 **Svelte 5 Runes 与 SvelteKit 生产级守则 (`rules/svelte-sveltekit.md`)**：全面废弃 Svelte 3/4 旧语法，强制使用 Svelte 5 符文（Runes: `$state`, `$derived`, `$props`），严禁滥用 `$effect()` 造成多轮重渲染/死循环，消灭 SSR 水合不匹配，原生 Form Actions 渐进增强（`use:enhance`）与 `.svelte.ts` 模块级防 SSR 用户间数据泄漏、无障碍无头组件（Bits UI / Melt UI）、View Transitions API 原生平滑页面过渡、基于 `@sveltejs/enhanced-img` 的编译期图片优化、`untrack()` 非响应式取值、基于 `use:enhance` 的乐观即时变更与失败回滚、Svelte 5 类型化 Snippets 替代旧 `<slot>`，以及 `PageServerLoad` 非关键数据流式传输。
- ⚛️ **Next.js 14/15 与 React 生产架构 (`rules/react-nextjs.md`)**：严格划分 App Router 服务端组件与客户端组件边界、适配 Next.js 15 异步请求 API（`await params`）、强制 `server-only` 防密钥泄露、Server Actions 权限与 Zod 校验、根除 Hydration 水合不匹配、基于 React Taint API (`experimental_taintUniqueValue` / `experimental_taintObjectReference`) 杜绝服务端敏感凭据向客户端泄露、`useTransition` 阻断非阻塞渲染，以及触觉微交互与高阶审美克制。
- 🦀 **Rust 工业级安全与 Tokio 异步规范 (`rules/rust.md`)**：生产代码严禁 `.unwrap()` / `.expect()`，强制 `Result<?>` 错误向上传播、严禁在 Tokio 异步工作线程中执行阻塞式计算与 I/O、跨 await 锁规范，杜绝无脑 `.clone()`。
- 🐍 **Python 与 FastAPI (`rules/python-fastapi.md`)**：强制全函数类型注解（Type Hints）、严格 Pydantic 校验，严禁静默吞掉报错的 `except Exception: pass`。
- 🤖 **多 Agent 协同与 MCP 协议 (`templates/AGENTS.md`)**：防 Context 衰减与膨胀机制、压缩式信息交接、Sub-agent 隔离，以及 Model Context Protocol (MCP) 工具调用与数据安全约束。
- 🎯 **原生支持现代化 Cursor `.mdc` 规则引擎**：所有规则均自带 YAML Frontmatter（包含 `globs` 自动匹配与 `description`），支持智能按需挂载。

---

## ⚡ 1 秒极速集成

在你的项目根目录下执行：

```bash
curl -fsSL https://raw.githubusercontent.com/TrustDec/agent-arsenal/main/install.sh | bash
```

或者直接按需复制到你的项目：
- 复制 `rules/CLAUDE.md` 到你的项目根目录（以及 `./.windsurfrules`, `./.clinerules`, `./.github/copilot-instructions.md`）
- 复制 `rules/.cursorrules` 到你的项目根目录（或将规则作为 `.mdc` 存入 `.cursor/rules/`）
- 复制 `skills/` 到你的 `.agents/skills/`
- 复制 `templates/AGENTS.md` 到你的 `AGENTS.md`

---

## 📂 仓库目录结构

```text
agent-arsenal/
├── rules/
│   ├── CLAUDE.md           # Claude Code, Windsurf, Copilot, Cline 主规则
│   ├── .cursorrules        # Cursor 经典根目录规则
│   ├── edge-serverless-workers.md # Cloudflare Workers、Durable Objects 与边缘计算运行时规范
│   ├── background-jobs-workflows.md # 分布式后台任务、持久化工作流与 Worker 规范
│   ├── context-memory-engineering.md # Agent 上下文工程、KV 缓存与记忆体系
│   ├── auth-identity.md    # OAuth 2.1, JWT 鉴权安全、Token 轮转与身份准则
│   ├── testing-discipline.md # 测试工程规范、防 Flaky 与反伪测试准则
│   ├── cicd-github-actions.md # Actions 供应链加固、命令注入免疫与 CI 安全
│   ├── api-distributed-systems.md # 高可用 API 设计、幂等性与分布式追踪规范
│   ├── ai-llm-rag.md       # AI, LLM 应用、RAG 检索增强与向量检索规范
│   ├── security-appsec.md  # 应用安全、SSRF 防御与 OWASP 严苛守则
│   ├── docker-containers.md# 容器化多阶段构建、无 root 运行与优雅停机规范
│   ├── kubernetes-cloud-native.md # 探针防雪崩、preStop零停机与k8s安全加固
│   ├── terraform-iac.md    # 远程状态锁、防误删保护与云 IaC 安全规范
│   ├── mcp-server.md       # Model Context Protocol (MCP) 服务端与工具生产规范
│   ├── typescript.md       # 严格类型、运行时校验与 Node/Bun 生产准则
│   ├── golang.md           # Go 并发安全、生命周期与系统级规范
│   ├── database-sql.md     # 数据库零停机迁移、索引与事务准则
│   ├── redis-caching.md    # Redis 缓存穿透击穿雪崩、分布式锁与 BigKey 防护
│   ├── kafka-event-streaming.md # Apache Kafka、再平衡防御、幂等生产者与 DLT 拓扑
│   ├── grpc-protobuf.md    # gRPC 与 Protocol Buffers 兼容性与流式通信规范
│   ├── websockets-realtime.md # WebSockets, SSE 实时流通信、心跳与重连抖动
│   ├── web-performance-vitals.md # Web 性能、Core Web Vitals (INP/LCP/CLS) 与运行时规范
│   ├── observability-telemetry.md # OpenTelemetry 链路追踪、Prometheus 与日志
│   ├── svelte-sveltekit.md # Svelte 5 Runes 与 SvelteKit 生产规范
│   ├── vue-nuxt.md         # Vue 3 响应式规范与 Nuxt 3 SSR 准则
│   ├── react-nextjs.md     # Next.js 15 App Router 与 Server Actions 生产边界
│   ├── rust.md             # Rust 工业级安全、Tokio 异步与反 unwrap 守则
│   └── python-fastapi.md   # Python 严格类型提示与 FastAPI 生产规范
├── skills/
│   ├── design-system/      # Apple/Vercel 级审美与 UI 设计系统
│   ├── code-discipline/    # Staff Engineer 外科手术式工程验证协议
│   └── context-engineering/# KV cache prefix 保护与记忆库协议
├── templates/
│   └── AGENTS.md           # 多 Agent 协同编排与 MCP 上下文管理规范
└── install.sh              # 1 键极速安装脚本（支持 Cursor, Claude Code, Windsurf, Copilot 等）
```

---

## 📄 开源协议

MIT © [TrustDec](https://github.com/TrustDec)
