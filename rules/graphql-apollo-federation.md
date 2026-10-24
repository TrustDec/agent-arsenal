---
description: GraphQL schema architecture, Apollo Federation v2 supergraphs, DataLoader N+1 elimination, query complexity and depth limits, persisted queries, and production API invariants
globs: **/*.graphql,**/*.gql,**/schema/**,**/resolvers/**,**/subgraphs/**,**/supergraph/**,**/apollo*.*,**/yoga*.*,**/codegen.ts,**/codegen.yaml
alwaysApply: false
---

# GraphQL Schema Architecture, Apollo Federation v2 & Supergraph Production Invariants

> Add these rules to your project if designing, building, or scaling GraphQL APIs, Apollo Federation v2 supergraphs/subgraphs, GraphQL Yoga/Envelop, Apollo Router, Apollo Client/Urql, or schema-first backends (TypeScript, Go/gqlgen, Rust/async-graphql, Python/Strawberry).

---

## 1. The N+1 Query Catastrophe & Request-Scoped DataLoader Invariant
The default execution model of GraphQL executes resolvers independently as a tree traversal. Without strict batching, resolving a list of 100 items with nested relations executes 1 initial query + 100 secondary queries (N+1 database or microservice calls), causing severe latency spikes and connection pool exhaustion.

- ❌ **THE MODULE-LEVEL DATALOADER MEMORY & TENANT LEAK TRAP**:
  - Instantiating a `DataLoader` instance at global or module scope caches data across independent client requests:
    ```ts
    // CATASTROPHIC BUG: Shared across all concurrent HTTP requests!
    // Leaks private tenant data between users and permanently bloats Node.js heap memory.
    export const userLoader = new DataLoader(async (userIds: readonly string[]) => {
      return db.users.findMany({ where: { id: { in: [...userIds] } } });
    });
    ```
- ✅ **The Request-Scoped DataLoader Context Invariant**:
  - ALWAYS instantiate DataLoaders afresh per incoming HTTP request inside the GraphQL execution context.
  - The loader's cache lives only for the lifespan of that single GraphQL request, preventing cross-tenant data pollution while deduplicating identical keys within the query execution plan:
    ```ts
    import DataLoader from 'dataloader';

    export interface GraphQLContext {
      userId?: string;
      tenantId: string;
      loaders: ReturnType<typeof createDataLoaders>;
    }

    export function createDataLoaders(tenantId: string) {
      return {
        userById: new DataLoader<string, UserRecord | null>(async (userIds) => {
          // Single batched SQL query for all users in this tick:
          const users = await db.query(
            `SELECT id, name, email, tenant_id FROM users WHERE tenant_id = $1 AND id = ANY($2)`,
            [tenantId, userIds]
          );

          // DataLoader invariant: Returned array MUST match the exact order and length of keys
          const userMap = new Map(users.map((u) => [u.id, u]));
          return userIds.map((id) => userMap.get(id) || null);
        }, {
          // Disable cross-batch caching if necessary, keep in-memory cache strictly per-request
          cache: true,
          maxBatchSize: 1000,
        }),
      };
    }
    ```
  - In field resolvers, always access loaders via `context.loaders`:
    ```ts
    export const resolvers = {
      Post: {
        author: async (parent: Post, _args: unknown, ctx: GraphQLContext) => {
          return ctx.loaders.userById.load(parent.authorId);
        },
      },
    };
    ```

---

## 2. Schema Resilience & The Partial Failure Nullability Contract
In GraphQL, fields are nullable by default. Adding an exclamation mark (`!`) marks a field non-null. However, over-specifying non-null types creates fragile schemas where minor downstream failures cascade catastrophically.

- ❌ **THE BUBBLING NULL DESTRUCTION TRAP**:
  - In the GraphQL specification, if a non-null field resolves to `null` (or throws an unhandled exception), the error bubbles up to the nearest nullable parent field.
  - If all ancestor fields and root query fields are typed as non-null (`user: User!`), a failure in a minor sub-field (e.g. `user.profile.loyaltyPoints!`) bubbles up and turns the entire root `data` object to `null`, completely crashing the client's screen.
- ✅ **The Semantic Nullability Invariant**:
  - **Entity Root Queries & Relations MUST be Nullable**: Downstream databases, microservices, and external APIs can fail or return missing data.
  - **List Semantics**:
    - `[Item!]!`: The list itself is never null (defaults to `[]`), and elements inside are never null. Use this only when elements are guaranteed to exist locally.
    - `[Item!]`: The list itself may be null (if service fails), but items inside cannot be null. This is the recommended resilient pattern for cross-service relations.
    - `[Item]`: Both list and items can be null. Use this for sparse datasets or federated entity references where individual items might be unreachable.
  - **Reserve Non-Null (`!`) strictly for**:
    - Primary record identifiers (`id: ID!`).
    - Mutation inputs that are required for business logic (`input: CreateUserInput!`).
    - Core domain invariants that have a hard database `NOT NULL` constraint and zero external service dependencies.

```graphql
type Query {
  # Nullable at the root: If the User service is down, this returns null + errors without killing the query
  user(id: ID!): User
}

type User {
  id: ID!
  email: String!
  # Resilient relations: If notification microservice is down, returns null; profile still renders
  unreadNotificationsCount: Int
  # Non-null elements inside a nullable array
  posts: [Post!]
}
```

---

## 3. Resilient Mutation Design: The Mutation Payload Pattern
Throwing top-level GraphQL errors for expected business validation failures (e.g., "Email already registered", "Password too weak") is an anti-pattern that breaks frontend error handling.

- ❌ **THE RAW GRAPHQL ERROR ANTIPATTERN**:
  - Throwing `new GraphQLError("Card expired")` puts errors in the top-level `errors` array alongside syntax errors, schema violations, and unhandled 500 server crashes.
  - Client UI libraries (Apollo Client, Urql, TanStack Query) treat top-level errors as network/transport exceptions, making granular form field error highlighting brittle and untyped.
- ✅ **The Mutation Payload & `UserError` Schema Invariant**:
  - Every mutation MUST accept a single typed input argument named `input`.
  - Every mutation MUST return a payload object containing:
    1. The modified domain record (nullable in case of error).
    2. A typed array of validation errors (`userErrors: [UserError!]!`).
  - Reserve top-level GraphQL `errors` exclusively for unexpected system crashes, authorization rejections (HTTP 401/403 equivalent), or schema syntax validation failures.

```graphql
input CreateUserInput {
  email: String!
  username: String!
}

type UserError {
  field: [String!] # JSON path to the erroneous input field, e.g. ["input", "email"]
  message: String!
  code: ErrorCode!
}

enum ErrorCode {
  VALIDATION_FAILED
  ALREADY_EXISTS
  INVALID_FORMAT
}

type CreateUserPayload {
  user: User
  userErrors: [UserError!]!
}

type Mutation {
  createUser(input: CreateUserInput!): CreateUserPayload!
}
```

```ts
// Resolver implementation:
export const mutationResolvers = {
  createUser: async (_: unknown, { input }: { input: CreateUserInput }, ctx: GraphQLContext): Promise<CreateUserPayload> => {
    const existing = await ctx.db.findUserByEmail(input.email);
    if (existing) {
      return {
        user: null,
        userErrors: [{
          field: ['input', 'email'],
          message: 'An account with this email address already exists.',
          code: 'ALREADY_EXISTS',
        }],
      };
    }

    const newUser = await ctx.db.createUser(input);
    return {
      user: newUser,
      userErrors: [],
    };
  },
};
```

---

## 4. Denial-of-Service Defense: Query Depth Limiting & Complexity Scoring
GraphQL grants clients immense flexibility. Malicious actors or unintentional infinite loops in frontend components can send arbitrarily deep recursive queries (e.g. `user { posts { author { posts { author { ... } } } } }`) that lock the CPU event loop, overwhelm database connections, and cause immediate denial of service.

- ❌ **THE UNRESTRICTED RECURSION TRAP**:
  - Executing an unconstrained GraphQL engine exposes the server to nested queries of arbitrary depth and magnitude.
  - A single HTTP POST payload of 2KB can trigger 10,000,000 recursive database reads.
- ✅ **Mandatory Defense-in-Depth Validation**:
  - **Query Depth Limiting**: Enforce a hard ceiling on AST query nesting (typically 6–10 levels max).
  - **Query Complexity Analysis**: Compute query cost statically before execution. Multiply list field complexities by their `limit` or `first` argument. Reject queries exceeding a safe threshold (e.g. 1,000 points).

```ts
import { depthLimit } from 'graphql-depth-limit';
import { createComplexityLimitRule } from 'graphql-validation-complexity';
import { createServer } from 'node-graphql-server';

const MAX_DEPTH = 8;
const MAX_COMPLEXITY = 1000;

export const validationRules = [
  // 1. Reject queries exceeding 8 nested levels:
  depthLimit(MAX_DEPTH),

  // 2. Compute cost based on field weights and pagination multipliers:
  createComplexityLimitRule(MAX_COMPLEXITY, {
    scalarCost: 1,
    objectCost: 2,
    listFactor: 10,
    onCost: (cost) => {
      // Export cost metrics to OpenTelemetry:
      queryComplexityMetric.record(cost);
    },
    formatErrorMessage: (cost) =>
      `Query complexity limit exceeded: requested cost is ${cost}, maximum permitted is ${MAX_COMPLEXITY}`,
  }),
];
```

---

## 5. Production Hardening: Introspection, APQ & Safelisting
In production, exposing your entire schema AST enables attackers to reverse-engineer administrative capabilities, undisplayed models, and beta features.

- ❌ **THE OPEN INTROSPECTION IN PRODUCTION VULNERABILITY**:
  - Leaving schema introspection enabled (`__schema`, `__type`) exposes internal microservice boundaries, experimental fields, and private data structures to public scanners.
- ✅ **The Hardened Production Protocol**:
  1. **Disable Introspection in Production**: Disable unless operating a public developer platform.
  2. **Automatic Persisted Queries (APQ)**:
     - Clients hash the query via SHA-256 and send `{ id: "<sha256>" }` over HTTP `GET`.
     - Reduces upload payload bandwidth by >95%.
     - Allows intermediate edge reverse proxies (Cloudflare, Fastly, NGINX) to cache GraphQL query responses via standard HTTP `Cache-Control` headers.
  3. **Operation Safelisting / Trusted Documents**:
     - For mobile apps and internal web frontends, extract all query ASTs at build time and generate a manifest of permitted SHA-256 hashes.
     - Reject ANY runtime GraphQL query whose hash is not present in the pre-approved manifest.

```ts
// Production Server Hardening configuration (GraphQL Yoga / Apollo Server / Envelop)
const isProduction = process.env.NODE_ENV === 'production';

export const serverConfig = {
  // Disable introspection and schema exploration in production
  introspection: !isProduction,

  // Enable Automatic Persisted Queries with Redis cache:
  persistedQueries: {
    cache: new RedisPersistedQueryCache(redisClient),
    ttl: 86400 * 7, // 7 days
  },

  // Reject ad-hoc dynamic queries if running in strict internal production mode:
  allowOnlyPersistedQueries: isProduction && process.env.REQUIRE_SAFELIST === 'true',
};
```

---

## 6. Apollo Federation v2 Supergraph Architecture & Subgraph Invariants
When decomposing large domains into microservices with Apollo Federation v2, follow explicit federation contracts to prevent supergraph composition failures and network thrashing.

- ❌ **THE FEDERATION SUBGRAPH CIRCULAR DEPENDENCY TRAP**:
  - If Subgraph A references an entity from Subgraph B, and Subgraph B requires fields from Subgraph A via circular `@requires` chains, the Supergraph router generates cyclic sub-queries, resulting in request deadlocks and 504 Gateway Timeouts.
- ✅ **Federation v2 Core Directives & Standards**:
  - **Entity Keying (`@key`)**: Define primary keys that uniquely identify an entity across subgraphs.
  - **`@shareable`**: Mark fields that can be resolved by more than one subgraph (must be declared in all participating subgraphs).
  - **`@inaccessible`**: Hide internal fields from the public supergraph gateway while keeping them accessible for federated resolution between subgraphs.
  - **Batched Entity Reference Resolvers (`__resolveReference`)**: Entity resolution inside subgraphs MUST use DataLoaders to avoid microservice-to-microservice N+1 network calls:

```graphql
# users-subgraph.graphql
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.5",
        import: ["@key", "@shareable", "@inaccessible"])

type User @key(fields: "id") {
  id: ID!
  email: String!
  username: String! @shareable
  internalBillingId: String @inaccessible
}
```

```graphql
# reviews-subgraph.graphql
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.5",
        import: ["@key"])

# Extend the User entity defined in users-subgraph:
type User @key(fields: "id") {
  id: ID!
  reviews: [Review!]!
}

type Review {
  id: ID!
  rating: Int!
  comment: String!
}
```

```ts
// Subgraph Entity Resolver with DataLoader (reviews-subgraph):
export const resolvers = {
  User: {
    // Apollo Federation calls __resolveReference when the router requests entity representation:
    __resolveReference: async (reference: { id: string }, ctx: GraphQLContext) => {
      // Must use DataLoader so multi-user queries batch reference lookups into 1 query:
      return ctx.loaders.userReviewSummaryLoader.load(reference.id);
    },
    reviews: async (user: { id: string }, _args: unknown, ctx: GraphQLContext) => {
      return ctx.loaders.reviewsByUserIdLoader.load(user.id);
    },
  },
};
```

---

## 7. Field-Level Authorization & Broken Object Level Authorization (BOLA) Defense
REST endpoints typically perform authorization checks in route middleware. In GraphQL, a single query can navigate deep object relationships, bypassing route-level checks and creating catastrophic IDOR / BOLA vulnerabilities.

- ❌ **THE DIRECT NODE LOOKUP IDOR VULNERABILITY**:
  - Exposing a generic `node(id: ID!)` or `order(id: ID!)` query that simply fetches records by primary key without checking tenant or ownership boundaries allows any authenticated user to read all orders across all tenants by iterating IDs.
- ✅ **Defense-in-Depth Authorization Protocol**:
  - Perform authorization checks inside the individual field and entity resolvers, never solely at the gateway entry point.
  - Always enforce tenant scoping in database filters alongside primary key lookups:

```ts
// Resolver-level authorization invariant:
export const orderResolvers = {
  Query: {
    order: async (_: unknown, { id }: { id: string }, ctx: GraphQLContext) => {
      if (!ctx.userId) {
        throw new GraphQLError('Unauthorized', {
          extensions: { code: 'UNAUTHENTICATED', http: { status: 401 } },
        });
      }

      // Enforce tenant boundary: Never search solely by ID
      const order = await ctx.db.orders.findFirst({
        where: {
          id,
          tenantId: ctx.tenantId, // Tenant isolation guard
          userId: ctx.userRole === 'ADMIN' ? undefined : ctx.userId, // Ownership guard
        },
      });

      if (!order) {
        throw new GraphQLError('Order not found', {
          extensions: { code: 'NOT_FOUND', http: { status: 404 } },
        });
      }

      return order;
    },
  },
  Order: {
    // Field-level authorization for sensitive payment metadata:
    paymentDetails: async (order: Order, _args: unknown, ctx: GraphQLContext) => {
      if (ctx.userRole !== 'ADMIN' && order.userId !== ctx.userId) {
        // Return null or throw specific forbidden error for sensitive nested fields
        return null;
      }
      return ctx.loaders.paymentDetailsByOrderId.load(order.id);
    },
  },
};
```

---

## 8. Real-Time Subscriptions: `graphql-ws` Protocol & Leak Prevention
Real-time GraphQL subscriptions hold open long-lived connections. Neglecting connection lifecycles leads to file descriptor exhaustion and subscriber memory leaks.

- ❌ **THE DEPRECATED `subscriptions-transport-ws` TRAP**:
  - The legacy `subscriptions-transport-ws` protocol is unmaintained, lacks modern ping/pong healthcheck primitives, and silently drops closed sockets.
- ✅ **The Modern `graphql-ws` Standard**:
  - Use the RFC-compliant `graphql-ws` library.
  - Enforce server-side heartbeat pings (e.g. every 15–30 seconds) to detect dead client connections.
  - Ensure subscription async generators register cleanup handlers via `return()` to remove event listeners from Redis or in-process PubSub brokers upon disconnect:

```ts
import { makeExecutableSchema } from '@graphql-tools/schema';
import { useServer } from 'graphql-ws/lib/use/ws';
import { WebSocketServer } from 'ws';

const wsServer = new WebSocketServer({
  server: httpServer,
  path: '/graphql',
});

useServer(
  {
    schema,
    // Authenticate during connection initialization handshake:
    onConnect: async (ctx) => {
      const authHeader = ctx.connectionParams?.authorization as string | undefined;
      if (!authHeader) {
        // Reject unauthenticated websocket upgrade:
        return false;
      }
      const user = await verifyToken(authHeader);
      // Attach authenticated identity to connection context:
      return { user };
    },
    // Keep alive ping interval to purge half-open sockets:
    keepAlive: 15_000,
  },
  wsServer
);
```

```ts
// Async Generator Subscription Resolver with Cleanup Invariant:
export const subscriptionResolvers = {
  Subscription: {
    orderStatusUpdated: {
      subscribe: async function* (_: unknown, { orderId }: { orderId: string }, ctx: GraphQLContext) {
        // Verify user owns this order before subscribing:
        await assertOrderAccess(ctx.user, orderId);

        const channel = `order:${orderId}`;
        const queue: OrderStatusUpdate[] = [];
        let resolveNext: (() => void) | null = null;

        const unsubscribe = ctx.pubsub.subscribe(channel, (payload: OrderStatusUpdate) => {
          queue.push(payload);
          if (resolveNext) {
            resolveNext();
            resolveNext = null;
          }
        });

        try {
          while (true) {
            if (queue.length === 0) {
              await new Promise<void>((resolve) => {
                resolveNext = resolve;
              });
            }
            yield { orderStatusUpdated: queue.shift()! };
          }
        } finally {
          // MANDATORY CLEANUP: Invoked automatically when the client disconnects or cancels
          unsubscribe();
        }
      },
    },
  },
};
```

---

## 9. Performance Checklist for Production GraphQL Deployments

| Risk Area | Anti-Pattern | Production Invariant |
| :--- | :--- | :--- |
| **Database I/O** | Resolving relations in sub-resolvers (`parent.id -> db.find`) | Request-scoped `DataLoader` batching via `ANY($1)` or `IN (...)` |
| **Memory / Leaks** | Global/singleton `new DataLoader()` instances | Fresh `createDataLoaders()` per request attached to execution context |
| **Error Handling** | Throwing raw `GraphQLError` for business validation | Typed `userErrors: [UserError!]!` returned in mutation payload |
| **Schema Security** | Leaving `__schema` introspection open in production | Introspection disabled; AST operation safelisting / APQ with SHA-256 |
| **DoS Attacks** | Unbounded cyclic queries (`user -> posts -> author -> ...`) | Query depth limit (max 8) + static query complexity scoring |
| **Nullability** | Over-specifying `!` on remote/external service types | Nullable relations (`[Post!]` or `[Post]`) to isolate partial failures |
| **Authorization** | Authorizing only at gateway route middleware | Field-level resolvers enforce tenant ID and user ownership filters |
| **Apollo Federation** | Unbatched `__resolveReference` entity resolvers | Batch entity reference resolution via DataLoader inside each subgraph |
| **WebSockets** | Unmonitored connections with legacy protocols | Modern `graphql-ws` with 15s keepAlive and generator `finally` cleanup |
