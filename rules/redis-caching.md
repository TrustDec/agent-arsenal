---
description: Redis in-memory caching, distributed locks, cache stampede prevention, BigKey mitigation, and high-throughput data store invariants
globs: **/*.{ts,js,go,py,rs,java},**/redis/**,**/cache/**
alwaysApply: false
---

# Redis & In-Memory Caching Production Invariants

> Add these rules to your project if using Redis, Dragonfly, KeyDB, or Memcached for high-throughput caching, rate limiting, session storage, or distributed coordination.

## 1. Algorithmic Safety & The Production Command Ban
- ❌ **ABSOLUTE BAN ON `KEYS *` IN PRODUCTION**:
  - Redis is single-threaded for command execution. Running `KEYS *` on a dataset with millions of keys blocks the event loop for seconds or minutes, starving all application traffic and causing cascading connection pool exhaustion.
  - ✅ **Always use cursor-based iteration**: Use `SCAN`, `SSCAN`, `HSCAN`, or `ZSCAN` with bounded `COUNT` batches (e.g., `COUNT 100`) to traverse keys without blocking the server.
- ❌ **NEVER USE `HGETALL` OR `SMEMBERS` ON POTENTIALLY UNBOUNDED KEYS**:
  - If a Hash or Set grows over 10,000 items (BigKey), fetching all elements blocks the Redis thread and swamps the network interface.
  - Check collection size first via `HLEN` or `SCARD`. Fetch targeted fields using `HMGET`, or paginate entries using `HSCAN` / `SSCAN`.
- **Use `UNLINK` Instead of `DEL` for Large Objects (Redis 4.0+)**:
  - `DEL` synchronously reclaims memory on the main execution thread. Deleting a key containing 100,000 entries introduces perceptible server latency spikes.
  - Use `UNLINK`, which decouples the key from the keyspace immediately and frees the allocated memory asynchronously in a background thread.
- **Accidental Flush Protection**:
  - In production configs, rename or disable catastrophic administrative commands:
    ```text
    rename-command FLUSHALL ""
    rename-command FLUSHDB  ""
    rename-command DEBUG    ""
    ```

## 2. Cache Failure Modes: Stampede, Avalanche & Penetration
- **Cache Stampede / Thundering Herd Prevention**:
  - When a high-traffic cache key expires, thousands of concurrent requests miss simultaneously and slam the backing database.
  - **Mitigation 1 (Singleflight / Mutex)**: Deduplicate concurrent in-flight fetch operations so only one database query is made, while sibling requests await the single result:
    ```go
    // Go singleflight deduplication
    val, err, _ := requestGroup.Do(key, func() (interface{}, error) {
        return fetchFromDatabase(ctx, id)
    })
    ```
  - **Mitigation 2 (Probabilistic Early Expiration / XFetch)**: Recompute the cached item before it expires if `time_left < -beta * delta * ln(rand())`:
    ```ts
    function shouldRecompute(cachedAt: number, ttlSeconds: number, computeTimeMs: number, beta = 1.0): boolean {
      const remainingMs = (cachedAt + ttlSeconds * 1000) - Date.now()
      return -computeTimeMs * beta * Math.log(Math.random()) > remainingMs
    }
    ```
- **Cache Avalanche Prevention (Mandatory TTL Jitter)**:
  - ❌ **NEVER set uniform static TTLs** (e.g., exactly `3600` seconds) across bulk-inserted keys. When they expire concurrently, database load spikes uncontrollably.
  - ✅ Always add randomized jitter (e.g., ±10–20%):
    ```ts
    const baseTTL = 3600 // 1 hour
    const jitter = Math.floor(Math.random() * (0.2 * baseTTL)) // 0 to 720 seconds
    const effectiveTTL = baseTTL + jitter
    ```
- **Cache Penetration Prevention**:
  - Malicious or errant queries for non-existent IDs bypass the cache completely and hit the database on every invocation.
  - **Mitigation 1**: Cache `NULL` or empty sentinel values with a short TTL (e.g., 60 seconds):
    ```ts
    if (!record) {
      await redis.set(cacheKey, "__EMPTY__", "EX", 60)
      return null
    }
    ```
  - **Mitigation 2**: Use a Bloom Filter (`BF.EXISTS` in RedisBloom) at the front edge to quickly reject definitely non-existent IDs without querying either Redis keyspace or SQL.

## 3. Distributed Locking Discipline
- ❌ **BAN ON NAIVE `SETNX` WITHOUT ATOMIC EXPIRATION**:
  - Executing `SETNX key value` followed by a separate `EXPIRE key ttl` call is non-atomic. An application crash or network partition between the two statements leaves a permanent deadlock.
  - ✅ Always acquire locks atomically with a single command:
    ```bash
    SET resource_lock <unique_uuid_token> NX PX 10000
    ```
- ❌ **BAN ON UNCONDITIONAL `DEL` TO RELEASE LOCKS**:
  - If Worker A holds a lock for 10s, but processing takes 12s, the lock auto-expires. Worker B acquires the lock. Worker A then executes `DEL resource_lock`, deleting Worker B's active lock!
  - ✅ Always release locks via an atomic Lua script that validates owner token equality:
    ```lua
    if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("del", KEYS[1])
    else
        return 0
    end
    ```
- **Bounded Lease & Watchdog**:
  - For long-running operations, implement a watchdog heartbeat goroutine/timer that periodically extends lock TTL while the worker is actively executing, and stops upon completion or panic.
- **Contention Backoff**:
  - When a lock acquisition fails, never tight-loop with zero delay. Use randomized exponential backoff with jitter to eliminate CPU spin and resonance lockouts.

## 4. Data Structure Discipline & Memory Efficiency
- **Choose Hashes for Partial Field Updates**:
  - ❌ Do not serialize large objects into JSON Strings if endpoints frequently read or mutate single attributes.
  - ✅ Use Hashes (`HSET`, `HGET`, `HINCRBY`) to mutate individual fields without reading, deserializing, modifying, and rewriting the entire JSON string.
- **Sliding Window Rate Limiter using Sorted Sets (ZSET)**:
  - Count events in a dynamic rolling window (e.g., 100 requests per 60 seconds):
    ```lua
    local key = KEYS[1]
    local now = tonumber(ARGV[1])
    local window = tonumber(ARGV[2])
    local limit = tonumber(ARGV[3])
    local clear_before = now - window

    redis.call('zremrangebyscore', key, '-inf', clear_before)
    local current_requests = redis.call('zcard', key)

    if current_requests < limit then
        redis.call('zadd', key, now, now)
        redis.call('expire', key, math.ceil(window / 1000))
        return 1
    else
        return 0
    end
    ```
- **HyperLogLog for Cardinality Estimation**:
  - When tracking unique pageviews, daily active users, or distinct IP counts where 1% standard error is acceptable, use `PFADD` and `PFCOUNT`. HyperLogLog consumes a fixed maximum of 12 KB memory regardless of millions of unique entries.
- **BigKey Sharding**:
  - Keep individual keys below 1 MB and under 5,000 collection items.
  - Shard large collections across deterministic hash buckets:
    ```text
    user_timeline:{userId}:{bucketId} where bucketId = eventTimestamp / 86400
    ```

## 5. Pipelining, Batching & Lua Script Constraints
- ❌ **NEVER EXECUTE SERIAL COMMANDS INSIDE LOOPS**:
  - Executing 50 individual `GET` or `SET` commands sequentially incurs 50 full network round trips (RTTs), multiplying latency by 50x.
  - ✅ Use `pipeline()` or `MGET` / `MSET` to batch network roundtrips into a single TCP packet exchange:
    ```ts
    const pipeline = redis.pipeline()
    for (const key of keys) {
      pipeline.get(key)
    }
    const results = await pipeline.exec()
    ```
- **Lua Script Atomicity & Execution Budget**:
  - Redis executes Lua scripts atomically; while a script runs, no other commands or scripts can execute.
  - ❌ **NEVER run unbounded loops, slow table iterations, or expensive mathematical calculations in Lua scripts**. Keep scripts bounded (< 5 ms).
  - Pre-load scripts using `SCRIPT LOAD` and execute via `EVALSHA` to avoid re-transmitting Lua script text over the network on every invocation.

## 6. Cache Consistency & Invalidation Invariants
- **Cache-Aside Pattern (Lazy Loading)**:
  - Read Path:
    1. Check Redis cache. On hit, return data immediately.
    2. On miss, read authoritative database.
    3. Write result into Redis with jittered TTL, then return.
  - Write Path:
    1. Mutate authoritative database within transactional boundary.
    2. **Commit** database transaction first.
    3. **Delete (invalidate)** the cache key in Redis.
- ❌ **NEVER UPDATE THE CACHE BEFORE COMMITTING THE DATABASE TRANSACTION**:
  - If the database transaction rolls back, Redis contains stale, phantom data.
  - If another thread reads from cache between cache update and DB commit, it reads uncommitted state.
- **Delete Over Update for Invalidation**:
  - Invalidate cache entries by deleting (`DEL` / `UNLINK`), rather than updating them with new data. Deletion is idempotent and avoids out-of-order write race conditions between concurrent mutations.
- **Fail-Open Resilience**:
  - Treat Redis as an ephemeral performance optimization, not an authoritative persistence layer (unless using Redis as primary storage).
  - If Redis connection times out or fails, wrap calls in a circuit breaker and fail-open to the database to prevent transient cache outages from taking down the whole application.
