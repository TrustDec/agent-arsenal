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

- 💳 **财务记账、复式记账法与支付系统生产级规范 (`rules/financial-ledgers-payment-systems.md`)**：货币金额绝对严禁浮点数运算陷阱（强制采用 ISO 4217 整数最小货币单位分/厘：cents/yen/fils，以 `BIGINT`/`int64` 存储）与银行家舍入法（Round Half to Even IEEE 754 消除统计正向偏差）、形式化复式记账会计恒等式（$\text{资产} + \text{费用} = \text{负债} + \text{所有者权益} + \text{收入}$）与延迟事务约束触发器保障 $\sum \text{借方} - \sum \text{贷方} = 0$、不可变只追加凭证流水（绝对严禁对历史记账流水执行 `UPDATE`/`DELETE`，所有纠偏必须通过红冲/冲正反向分录处理）、原子余额扣减带守卫条件（`WHERE balance >= :debit_amount`）杜绝并发超额双花、转账账户 UUID 字典序排序加排它锁（`SELECT FOR UPDATE WHERE id IN (...) ORDER BY id ASC`）彻底终结并发交叉转账死锁、两阶段支付生命周期规范（授权与结算分离 Auth & Capture 消除未履约退款手续费损耗）、Webhook 回调安全防线（验签强制采用未反序列化的纯原始 Buffer 载荷比对、基于 `crypto.timingSafeEqual` 消除签名比对时序侧信道攻击、300 秒时间戳窗口防重放）、预持久化纪律（严禁在本地数据库记录生成前调用三方支付网关扣款，规避网络抖动导致用户被扣款却无订单的严重灾难）、事务性发件箱（Transactional Outbox）保障支付成功领域事件可靠发布、每日三方自动化对账与结算引擎（支付渠道结算单 vs 内部账本明细 vs 银行流水三向勾兑）、PCI-DSS Level 1 范围最小化与零 PAN 卡号准则（通过前端 Hosted Fields 令牌化，后端零触碰敏感卡号并部署 Luhn 算法日志脱敏过滤）。
- 🧬 **向量数据库、嵌入表征与语义检索生产级规范 (`rules/vector-databases-embeddings.md`)**：预归一化单位向量准则（$\|\mathbf{v}\|_2 = 1.0$）与内积/点积（`<#>`, `ip`）硬件 SIMD 加速替代耗时的未归一化余弦距离开方运算、HNSW 索引拓扑参数科学调优（$M$, $\text{ef\_construction}$, $\text{ef\_search}$）与常驻物理内存精确估算公式（$\text{RAM} \approx N \times (\text{dim} \times 4 + M \times 16) \times 1.25$）杜绝宿主内存溢出 OOM 与频繁磁盘 Swap 抖动、后过滤（Post-Filtering）召回率塌缩灾难与前过滤无索引全表扫描排查（Qdrant/pgvector 强制为 Payload 元数据字段显式创建倒排索引）、标量量化（Scalar Quantization SQ8 / int8）结合 $3 \times$ 超采样重新打分（Rescoring）节约 75% 内存开销并保障 >99% 高召回、pgvector 0.7+ 半精度浮点 `halfvec` (FP16) 存储与内存减半优化、海量向量批量构建纪律（先通过 `COPY` 导入数据，再配合 `maintenance_work_mem = '4GB'` 与 `max_parallel_maintenance_workers = 4` 并发建 HNSW 索引）、PostgreSQL HNSW 垃圾元组 MVCC 膨胀防线（不可变向量表与高频元数据表物理解耦）、嵌入模型来源血统与维度一致性防线（严禁跨模型盲目比对）、非对称检索指令前缀强规范（E5/BGE/Nomic 系列之 `passage: ` 与 `query: `）、密集向量与 BM25 词法全文倒排融合之倒数排名融合（RRF $k=60$）混合检索、双阶段检索架构结合交叉编码重排器（Cross-Encoder Reranker: Cohere Rerank / BGE-Reranker-Large），以及多租户声明式分区隔离与单分区局部 HNSW 索引。
- 🕸️ **GraphQL Schema 架构、Apollo Federation v2 与超图 (Supergraph) 生产级规范 (`rules/graphql-apollo-federation.md`)**：N+1 级联查询灾难与 DataLoader 请求上下文单次实例化纪律（强制每个请求上下文动态调用 `createDataLoaders()` 工厂，绝对严禁模块全局单例跨请求泄漏租户数据或常驻内存）、Schema 弹性与局部降级可空契约（语义化可空设计，关联字段强制保留可空 `[Item!]` 规避下游故障导致根节点整体覆灭，非空 `!` 严格收敛于 ID 与核心必填入参）、弹性 Mutation 突变设计与强类型 `userErrors: [UserError!]!` 载荷规范（严禁将业务校验失败作为顶级 GraphQLError 抛出）、抗 DoS 攻击强防线（静态 AST 查询深度上限 6–10 层与基于字段加权及列表乘数的查询复杂度评分预算）、生产环境安全加固（生产环境彻底关闭 `__schema` 内省、强制开启基于 SHA-256 的自动持久化查询 APQ 与客户端操作白名单）、Apollo Federation v2 超图编排与子图规范（`@key`, `@shareable`, `@inaccessible`, `@override` 与实体引用解析器 `__resolveReference` DataLoader 批量化）、字段级精确鉴权与越权（BOLA/IDOR）租户边界强隔离，以及基于现代化 `graphql-ws` 协议的长连接心跳保活与异步生成器 `finally` 资源注销闭环。
- 🌐 **NGINX、反向代理与 Ingress 网关生产级规范 (NGINX, OpenResty, Caddy & Traefik) (`rules/nginx-reverse-proxy.md`)**：Off-by-slash 目录遍历安全漏洞防御（`location` 路径与 `alias` 目标路径严格末尾斜杠对齐）、`proxy_pass` 尾部斜杠重写陷阱（透明原样转发 vs 路径前缀剥离）、上游长连接池（`proxy_http_version 1.1; proxy_set_header Connection ""; keepalive 64;`）彻底消除 `TIME_WAIT` TCP 套接字耗尽与建连延迟、容器与云原生环境动态 DNS 解析防线（运行时动态变量绑定配合 `resolver ... valid=10s` 防旧 Pod 下线报 502 宕机）、WebSocket 逐跳动态升级映射（`map $http_upgrade $connection_upgrade`）、Server-Sent Events (SSE) 与 LLM Token 流式传输优化（`proxy_buffering off; chunked_transfer_encoding on;`）、真实客户端 IP 还原与防伪造加固（`set_real_ip_from`、`real_ip_header`、`real_ip_recursive on`）、内存代理缓冲区调优（`proxy_buffers 8 32k; proxy_busy_buffers_size 64k;`）根除临时磁盘外排 I/O 抖动、客户端请求体上限隔离（`client_max_body_size`）、基于 `$binary_remote_addr` 与 `burst`/`nodelay` 的高并发限流与 HTTP 429 响应、现代 TLS/SSL 安全加固（强制 TLS 1.2/1.3、AEAD 现代密码套件、OCSP Stapling、HSTS `preload`、`server_tokens off;`）、零停机原子语法检测与平滑热重载（`nginx -t && nginx -s reload`），以及 SPA 单页应用静态资源长缓存与路由回退防线。
- 🔍 **搜索引擎、倒排索引与混合检索生产级规范 (Elasticsearch, OpenSearch & Meilisearch) (`rules/search-elasticsearch-meilisearch.md`)**：零停机索引平滑迁移与双别名强制抽象规范（读别名 `_search` 与写别名 `_write`、原子 `_aliases` 切换）、显式 Mapping 映射纪律与严禁无限制动态映射（`dynamic: strict` / `dynamic: false`，彻底根绝 Mapping 爆炸与 Master 节点 JVM 堆内存 OOM 宕机）、`text`（切词全文倒排检索）与 `keyword`（精确值、过滤、排序与聚合）严格分工、严禁在 `text` 字段启用内存 Fielddata、深度分页死锁防御（全面严禁 `from + size > 10,000` 内存雪崩，强制使用快照级 Point-in-Time `_pit` 配合带唯一 Tie-breaker 的 `search_after`）、Bulk 批量写入尺寸规范（5MB–15MB / 1,000–5,000 篇文档）与背压防护（HTTP 429 `TOO_MANY_REQUESTS` / `EsRejectedExecutionException` 抖动指数退避）、分片科学定容（检索场景 10GB–30GB，日志时序 30GB–50GB）与多租户自定义 `routing` 散列路由（单分片精确命中，消灭全集群 Scatter-Gather 广播开销）、Filter 上下文（64 位 Roaring Bitmaps 内存缓存与免打分）vs Query 上下文、前缀通配符绝对禁令（`*term*` 全字典扫描拦截与 Edge N-gram 替代方案）、密集向量 HNSW 嵌入与 BM25 词法混合检索之倒数排名融合（RRF）算法集成，以及 Meilisearch 生产准则（显式配置 `searchableAttributes`、`filterableAttributes` 与 `sortableAttributes`、字符串主键约束与异步任务队列 `waitForTask` 协同）。
- 📦 **Monorepo 多包工程、工作区边界与构建图谱严苛规范 (`rules/monorepo-workspaces.md`)**：包管理器纯洁性保障（强制 `only-allow pnpm` 拦截异构包管理器介入、零容忍多余 Lockfile 污染 CI 构建与依赖幽灵提升）、根目录与子包依赖严格分流（运行时与构建依赖严格下沉至具体子包 `package.json`，根目录仅保留仓库级编排与代码质量脚手架）、内部子包连接全面强制 `workspace:*` 协议、全面严禁跨包物理相对路径穿透引入（`import { x } from '../../packages/core/src/internal/...'` 红线）、现代 `package.json` `exports` 条件导出与子路径深度封装（`types`, `import`, 私有文件严格不可见）、严格有向无环依赖图（DAG）校验（`madge --circular` 防循环依赖打崩构建器）、TypeScript Project References 复合工程架构（子包 `composite: true`、`declarationMap: true` 保障 IDE 跳转直达源码而非 `.d.ts` 声明文件、根目录 `tsc --build` 级联跳过未改动子包）、Turborepo/Nx 流水线任务缓存（`dependsOn: ["^build"]`、严谨 `inputs`、环境变量声明至 `env` 防远程缓存交叉污染）、AI Agent 专属过滤执行纪律（全面限制跨包全局执行，强制 `pnpm --filter <pkg>...` 与 `turbo run test --filter=...[origin/main]` 有界排查防上下文爆炸）、Changesets 变更意图驱动的多包语义化发布（`.changeset/`），以及双 ESM/CJS 库级 `tsup` 零漂移打包标准。
- 🗃️ **SQLite、DuckDB 与嵌入式进程内存储生产级规范 (`rules/sqlite-duckdb-embedded.md`)**：强制初始化 PRAGMA 生产基线调优（`journal_mode = WAL` 读写并发、`synchronous = NORMAL` 兼顾持久化与消除 90% fsync 开销、`busy_timeout = 5000` 规避即时 `SQLITE_BUSY` 报错、`foreign_keys = ON` 强制启用外键约束、`cache_size = -64000` 扩容 64MB 页缓存、`temp_store = MEMORY` 内存排序、`mmap_size = 256MB` 零拷贝内存映射）、并发架构单写多读互斥锁纪律（严守 WAL 模式下多读者并发而单瞬时绝对唯一写入者约束）、全面严禁推迟式 `BEGIN` 升级写锁死锁陷阱（写事务强制 `BEGIN IMMEDIATE` 预占排它锁）、SQLite 3.37+ `STRICT` 强类型表约束、ISO-8601 UTC 字符串日期时间规范、存储型（`STORED`）计算列与 JSON 表达式索引、外部内容 FTS5 全文搜索虚拟表（`content='...'`）与轻量触发器同步（`AFTER INSERT/UPDATE/DELETE`）、基于 BM25 算法的加权相关性排序与 Trigram 子串通配切词器、DuckDB 向量化进程内分析引擎直读多 GB 级别 Parquet/CSV 文件（零 Python 内存开销与谓词下推）、宿主进程严格内存上限（`SET max_memory = '4GB'`）与磁盘外排溢出保护防 OOM Kill、零拷贝 Apache Arrow RecordBatch 内存交换、直接附加 SQLite 运行库进行秒级 OLAP 聚合分析（`ATTACH ... AS sqlite_db`）、12 步零停机表结构重建无损数据迁移演进法、无阻塞非切断在线热备份（`VACUUM INTO` 根除文件拷贝损坏）、WAL 检查点与增量整理，以及客户端生成 UUID v7 保障边缘分布式同步零主键冲突（Turso/libSQL 与 Cloudflare D1）。
- 📊 **ClickHouse 与实时列式 OLAP 分析严苛规范 (`rules/clickhouse-olap.md`)**：列式存储执行模型与 MergeTree 家族表引擎选型（`ReplacingMergeTree` 去重、`VersionedCollapsingMergeTree` 状态消除、`AggregatingMergeTree` 预聚合）、全面严禁单条记录 OLTP 式写入（强制客户端微批处理 10,000–100,000 条或开启服务端 `async_insert=1` 缓冲，根除致命 `Too many parts` 宕机）、按月粗粒度分区剪枝（`toYYYYMM`）与活跃分区数严控（<1,000）、`ORDER BY` 物理排列与稀疏主键索引最左原则（低基数列居首）、`SELECT ... FINAL` 性能劣化防线与基于 `argMax` 的 SIMD 向量化去重加速、热路径绝对严禁重型异步变更（`ALTER TABLE ... UPDATE/DELETE` 磁盘重写）、声明式数据 TTL 自动过期、`LowCardinality(String)` 字典编码节约 85% 存储与整数过滤、严控 `Nullable(T)` 掩码惩罚、流式写入物化视图（Materialized View）搭配 `AggregatingMergeTree` 实现亿级事件 15 毫秒瞬时聚合、查询内存上限与磁盘外排溢出保护（`max_memory_usage`）、分布式 `GLOBAL JOIN` 规避节点间全量笛卡尔扇出，以及基于 HyperLogLog 算法的高性能近似基数统计（`uniq` / `uniqCombined64`）。
- 💻 **Shell 脚本工程、Bash 自动化与 POSIX CLI 生产级规范 (`rules/shell-bash-cli.md`)**：强制启用现代严格模式（`set -euo pipefail` 与 `IFS=$'\n\t'`）、变量强制双引号包裹消灭分词与通配符展开漏洞、规避 `local` 声明结合命令替换掩盖非零退出码陷阱（强制 `local x` 声明与 `x=$(cmd)` 赋值分离）、基于 `BASH_SOURCE[0]` 实现脚本绝对路径自解析锚定、基于 `mktemp -d` 与信号捕捉机制实现临时目录原子清理（`trap cleanup EXIT INT TERM`）、写临时文件后原子重命名替换目标文件（`mv -f temp dest`）、基于 `while IFS= read -r line` 规避 `for line in $(cat ...)` 的分词崩溃、毁灭性递归删除前置空变量校验强防线（`rm -rf "${DIR:?}"/*` 杜绝误删根目录）、标准流分离（STDOUT 专供机器消费，STDERR 专供人类诊断日志）、强制内置 `command -v` 验证依赖可用性，以及 CI/CD 与 Agent 自动化环境非交互标志规范。
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
- 🐹 **Golang 并发与系统工程 (`rules/golang.md`)**：强制 `context.Context` 规范传递、`errgroup` 协同工作与严防 Goroutine 泄露、切片子切片底层数组内存截留排查（`bytes.Clone` / `slices.Clone`）、Go 1.23+ range-over-func 标准迭代器规范（`iter.Seq` / `iter.Seq2`）与 yield 契约、`http.Client` Transport 连接池复用与响应体强制 Drain 排水排查（`io.Copy(io.Discard, resp.Body)`）与 `MaxIdleConnsPerHost` 套接字池耗尽防御、测试必带 `go test -race`、错误使用 `%w` 与 `errors.Is/As` 保持因果链、Go 1.20+ 多错误合并 `errors.Join`、Go 1.21+ `context.AfterFunc` 异步取消回调、编译器逃逸分析优化（`go build -gcflags="-m"`）、切片预分配消除 `growslice` 阶梯扩容抖动、生产代码零 panic 与优雅停机（`signal.NotifyContext` 配合带超时的 `srv.Shutdown` 排水）、容器环境配置 `GOMEMLIMIT` 与 `GOGC` 步调规避 cgroup OOM Kill 崩溃、64 位结构体字段降序内存对齐（`fieldalignment` 消除死填充字节）、Go 1.21+ `sync.OnceFunc` 懒加载单例、后台 Goroutine 必须配备 `defer recover()` 恐慌防线、切片与 Map 容量预分配（`make(..., cap)`）、Go 1.21+ `log/slog` 强类型属性（零反射分配）、有类型 nil 指针转接口判空陷阱规避、`singleflight.Group` 击穿合并抑制、`ctx.Err()` 批处理循环即时中止检查、非公开内部 `pprof` 端口安全防线、`sync.Pool` 内存截留排查与指针语义分配（规避装箱并设置容量熔断）、通道方向强类型化与单所有者安全关闭原则、禁止 Mutex 值传递拷贝、基于 `atomic.Pointer[T]` 的无锁并发热更与免锁只读、Go 1.22+ 循环变量作用域规范与跨版本兼容、两阶段优雅停机（网关流量排水 vs 状态存储释放）、通道发送 Goroutine 泄露防线（`select` 与 `ctx.Done()` 守护）、基于 `http.MaxBytesReader` 的请求体内存上限防 OOM 注入反爬、`runtime.KeepAlive` 守护 cgo/系统调用底层资源防过早 GC 终结、带并发上限的有界信号量协程池控制、基于 `context.WithoutCancel`（Go 1.21+）解耦异步审计任务规避请求结束过早取消、基于 `io.Pipe` 管道零内存堆积直连上传流，以及基于非阻塞 `select default` 与原子计数器的指标/审计事件防拥塞上报。
- 🗄️ **SQL 与数据库生产级安全 (`rules/database-sql.md`)**：严守 Expand & Contract 零停机迁移法、生产接口严禁 `SELECT *`、复合索引最左前缀原则、软删除部分索引（Partial Index）、PostgreSQL 并发建索引、SQL 参数化防注入、超短事务与严禁事务内发起网络 I/O、PostgreSQL 事务级咨询锁（`pg_advisory_xact_lock`）、PgBouncer 事务连接池模式安全禁令（禁会话级状态与 Little's Law 连接池科学定容：`(2 * CPU cores) + disks`）、JSONB GIN `jsonb_path_ops` 与表达式索引选型、PostgreSQL 事务 ID (XID) 回卷 Autovacuum 激进调优（`autovacuum_vacuum_cost_limit = 2000` 与事务年龄监控）、海量数据表声明式 Range 分区与零锁秒级分区清理、分区剪枝优化、PostgreSQL Heap-Only Tuple (`HOT`) 原地行更新与 `fillfactor` 调优消灭索引写放大、批量更新升序死锁防御、两步走零停机添加外键与检查约束（`NOT VALID` -> `VALIDATE CONSTRAINT` 规避全表独占排它锁）、存量超大表三步走安全追加 `NOT NULL` 约束、零停机枚举演进（`ALTER TYPE ADD VALUE` 事务外独立提交）、编译期常量 vs 易失性动态函数 `NOT NULL` 默认值全表重写冻结防线、DDL 强制包裹显式 `lock_timeout = '2s'` 与 `statement_timeout = '10s'` 彻底终结排它锁排队死锁级联瘫痪、基于 `FOR UPDATE SKIP LOCKED` 的高并发无饥饿任务队列、覆盖索引（`INCLUDE`）纯索引扫描、时序递增 UUIDv7 替代随机 UUIDv4 根除 B-Tree 页分裂与缓存震荡、强制外键列建索引、读-改-写并发丢失更新（Lost Updates）防线（原子算术、行锁与 OCC 乐观锁）、高频队列状态表部分索引（Partial Index）、多列相关性统计信息（`CREATE STATISTICS`）、pgvector HNSW 与 IVFFlat 向量索引生产准则（余弦 `<=>` 与内积 `<#>` 距离算子和 `maintenance_work_mem` 构建内存）、MVCC 垃圾死元组膨胀与 Autovacuum 激进调优（`autovacuum_vacuum_scale_factor = 0.02`）、并发事务隔离异常重试机制、Row-Level Security (RLS) 行级安全查询计划索引陷阱与 `security_invoker = true` 视图防越权、高频数据暂存 `UNLOGGED` 表免写 WAL 防线、PostgreSQL `work_mem` 算子级内存定容（`SET LOCAL work_mem` 防整机并发 OOM Kill 崩溃），以及基于 `track_io_timing = on` 与 `auto_explain` 的生产级零侵入慢查询执行计划自动化捕获。
- ⚡ **Redis 与高并发缓存生产级规范 (`rules/redis-caching.md`)**：全面严禁生产环境执行 `KEYS *` 阻塞主事件循环（强制游标式 `SCAN`/`SSCAN` 分批）、大键异步内存释放（`UNLINK` 替代阻塞式 `DEL`）、基于 Singleflight 与 XFetch 概率性提前过期根治缓存击穿（Stampede）、强制 TTL 动态抖动（Jitter）消灭缓存雪崩、防范缓存穿透（空值短期缓存与 Bloom Filter）、原子令牌校验 Lua 脚本安全释放分布式锁、基于有序集合（ZSET）的滑动窗口限流器，以及 Cache-Aside 事务提交后失效（Delete over Update）一致性原则。
- 📨 **Apache Kafka 与事件流生产级架构规范 (`rules/kafka-event-streaming.md`)**：强制开启幂等生产者（`enable.idempotence=true`）、严守 `acks=all` 与 `min.insync.replicas=2` 绝对防丢数据契约、分区键散列设计消灭倾斜热点分区、消费者 Poll 循环心跳守护（严防处理耗时超标 `max.poll.interval.ms` 触发再平衡雪崩）、全面严禁自动提交 Offset（`enable.auto.commit=false` 根除停机丢消息）、采用 `CooperativeStickyAssignor` 根治“全局停顿”再平衡风暴、三层非阻塞重试与死信队列（DLT）拓扑、Schema Registry 兼容性演进准则（BACKWARD/FULL），以及基于 `wakeup()` 与 Flush 的优雅停机闭环。
- 📊 **可观测性、OpenTelemetry 与生产遥测规范 (`rules/observability-telemetry.md`)**：全面严禁生产代码裸写 Print（强制结构化 JSON 日志）、敏感数据脱敏防线（请求头/密码/Token/卡号自动过滤）、Prometheus 标签基数爆炸防御（绝对严禁将 user_id/order_id/动态路径放入 metric labels 炸毁 TSDB）、Counter/Gauge/Histogram 四大黄金信号指标语义、跨进程/跨网络 W3C `traceparent` 链路上下文透传、OpenTelemetry Span 完整生命周期闭环与显式错误状态标记（`StatusCode.ERROR`），以及存活/就绪探针解耦（`/livez` 绝不探测外部数据库）。
- ⚡ **gRPC 与 Protocol Buffers 生产级规范 (`rules/grpc-protobuf.md`)**：二进制协议兼容性绝对保障、字段编号（Tag）一旦发布终生不可篡改复用、字段废弃强制 `reserved` 标记锁定、枚举项首位强制 `ENUM_TYPE_UNSPECIFIED = 0` 根除默认值语义伪造、proto3 `optional` 显式判空防踩坑、W3C `grpc-timeout` 超时截止时间链路逐级透传、标准 gRPC 状态码规范映射（`codes.InvalidArgument`/`codes.NotFound`/`codes.FailedPrecondition`）、基于 `google.rpc.Status` 与 `BadRequest.FieldViolation` 的强类型富错误模型、流式 RPC 队列背压与客户端断连即时退出、单例 `ClientConn` 连接复用、NAT/负载均衡长连接心跳保活与防刷屏配置（`KeepaliveEnforcementPolicy`），以及拦截器分层编排（Recovery 居首）。
- 📡 **WebSockets、Server-Sent Events (SSE) 与实时流通信规范 (`rules/websockets-realtime.md`)**：协议选型架构矩阵（LLM Token 流与通知首选 SSE，双向交互/协同画布选用 WebSocket）、全面严禁客户端高频短轮询、原生 Ping/Pong 控制帧心跳守护与僵尸连接剔除、全抖动（Full Jitter）指数退避彻底免疫重连风暴、单调递增消息 ID 与服务端环形重放缓冲区保障断网重连无损补发、严格有界出站队列与慢消费者淘汰机制（防服务端堆积 OOM）、基于分布式 Pub/Sub（Redis Streams/NATS）跨节点多 Pod 扇出、滚动发布发送 WebSocket `1001 (Going Away)` 优雅断链避震，以及跨站 WebSocket 劫持（CSWSH）`Origin` 严格白名单校验。
- ⚡ **Web 性能、Core Web Vitals 与浏览器运行时规范 (`rules/web-performance-vitals.md`)**：严禁在 UI 事件监听器中执行 >50ms 长任务（保障 Interaction to Next Paint / INP < 200ms）、基于 `scheduler.yield()` 与宏任务向浏览器渲染管道让出主线程控制权、强制读写分批执行（`requestAnimationFrame`）彻底根除布局抖动与强制同步回流（Layout Thrashing）、Cumulative Layout Shift (CLS < 0.1) 强防线（多媒体强制尺寸/比例占位与字体度量修正 `size-adjust` 消除 FOUT 偏移）、Largest Contentful Paint (LCP < 2.5s) 首屏大图优先级（`fetchpriority="high"` 与 `loading="eager"` 严禁懒加载）、DOM 树节点预算上限（<1,500 节点）与超长列表虚拟化（Virtualization）、重型三方库动态代码分割（Code Splitting），以及游离 DOM 内存泄漏排查。
- 💚 **Vue 3 与 Nuxt 3 响应式与 SSR 严苛守则 (`rules/vue-nuxt.md`)**：强制 `<script setup lang="ts">`、Vue 3.4+ `defineModel()` 声明式双向绑定规范、Vue 3.5+ `useId()` 水合安全无障碍 ID 生成、适配 Vue 3.5+ 响应式 Props 解构与 `useTemplateRef()`、使用 `onWatcherCleanup()` 规范取消异步竞态、组合式函数参数基于 `toValue` 与 `MaybeRefOrGetter` 规范化、SSR 模板严禁非确定性 API、严禁覆写 `reactive()` 对象引用、绝对严禁在 Nuxt SSR 模块作用域声明可变状态（根治多租户跨请求数据串扰重大漏洞）、Nitro 服务端接口强制 `readValidatedBody` 运行时校验与服务端中间件内存泄漏排查、Nitro 服务端接口基于 `defineCachedEventHandler` 的多租户隔离缓存（`getKey` 作用域隔离）、Nuxt 3 路由中间件强制返回导航指令（`return navigateTo(...)`）、Pinia 状态解构必配 `storeToRefs` 与 `onScopeDispose` 组合式函数事件监听自动注销、虚拟长列表 `v-memo` 跳过子树 VDOM Diff 极致加速、无障碍无头组件库（Radix Vue / Reka UI）与键盘焦点捕获（Focus Trap）、Teleport 客户端挂载防御与 SSR 水合防崩溃、Nuxt 媒体尺寸优化与 GPU 硬件加速过渡、带回滚机制的乐观 UI 更新、海量数据集 `shallowRef` 与 `markRaw` 深度 Proxy 内存膨胀抑制（针对画布/代码编辑器实例）、`<NuxtErrorBoundary>` 与 `onErrorCaptured` 粒度化异常边界隔离、基于 `definePayloadReducer` 与 `definePayloadReviver` 的复杂自定义对象水合保真、SSR 安全浏览器 API 防线（`import.meta.client` 与 `onMounted` 隔离）、`useAsyncData` 参数化动态键唯一隔离，以及基于 `customRef` 的高性能防抖输入。
- 🧡 **Svelte 5 Runes 与 SvelteKit 生产级守则 (`rules/svelte-sveltekit.md`)**：全面废弃 Svelte 3/4 旧语法，强制使用 Svelte 5 符文（Runes: `$state`, `$derived`, `$props`），Svelte 5 `$derived.by()` 复杂多语句派生计算、Svelte 5 `$bindable()` 显式双向绑定契约约束，严禁滥用 `$effect()` 造成多轮重渲染/死循环、严禁在 `$effect` 内部同步修改 `$state` 根除微任务级联死循环、基于 `$effect.pre()` 进行 DOM 绘制前几何尺寸测量、`untrack()` 显式排除非响应式依赖订阅、SvelteKit 服务端安全边界隔离（私有凭据与数据库操作严格限定于 `+page.server.ts` 杜绝泄露至通用 `+page.ts` 客户端 Bundle）、消灭 SSR 水合不匹配，原生 Form Actions 渐进增强（`use:enhance`）结合 CSRF 防护与 `fail(400, ...)` 无刷新回传校验错误、`.svelte.ts` 通用响应式状态类模块（Svelte 5 Class Stores）、无障碍无头组件（Bits UI / Melt UI）、View Transitions API 原生平滑页面过渡、基于 `@sveltejs/enhanced-img` 的编译期图片优化、粒度化缓存失效（`invalidate(url)` 优于 `invalidateAll()`）、基于 `use:enhance` 的乐观即时变更与失败回滚、Svelte 5 强类型 Snippets（`{#snippet}` / `{@render}`）全面替代废弃 `<slot>`、基于 `hooks.server.ts` `handleFetch` 钩子的内部微服务调用鉴权 Token 透传与重写、基于 `snapshot` API 的离开页面表单草稿与滚动状态无损恢复，以及 SvelteKit `load` 函数非阻塞 Deferred Promise 流式渐进渲染保障瞬间 TTFB 首屏体验。
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
│   ├── financial-ledgers-payment-systems.md # 财务复式记账、Stripe/Adyen 与 PCI-DSS 支付规范
│   ├── vector-databases-embeddings.md # 向量数据库、HNSW 索引调优、量化与混合检索
│   ├── graphql-apollo-federation.md # GraphQL、Apollo Federation v2 超图与 Schema 规范
│   ├── nginx-reverse-proxy.md # NGINX、反向代理、SSE 流式传输与网关安全
│   ├── search-elasticsearch-meilisearch.md # Elasticsearch、OpenSearch 与 Meilisearch 检索规范
│   ├── monorepo-workspaces.md # Monorepo 多包边界、Turborepo、pnpm 与 Changesets
│   ├── sqlite-duckdb-embedded.md # SQLite WAL 调优、单写多读互斥锁、FTS5 与 DuckDB OLAP
│   ├── clickhouse-olap.md  # ClickHouse 列式 OLAP、MergeTree 引擎与分析规范
│   ├── shell-bash-cli.md   # Shell/Bash 自动化、严格模式与 CLI 生产规范
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
