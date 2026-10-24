---
description: Monorepo architecture, Turborepo, Nx, pnpm workspaces, package boundary isolation, TypeScript project references, package exports, and Changesets versioning
globs: **/pnpm-workspace.yaml,**/turbo.json,**/nx.json,**/package.json,**/packages/**,**/apps/**,**/.changeset/**,**/tsconfig*.json
alwaysApply: false
---

# Monorepo Architecture, Workspace Boundaries & Build Graph Invariants

> Add these rules to your project if developing in a multi-package repository (Turborepo, Nx, pnpm/Bun/Yarn workspaces), micro-frontend ecosystem, shared component library, fullstack application with internal packages, or multi-service codebase.

---

## 1. Package Manager Purity & Lockfile Hygiene
In a monorepo, having mixed package managers or corrupted lockfiles leads to irreproducible CI builds, ghost phantom dependencies, and dependency resolution conflicts across packages.

- ❌ **TOTAL BAN ON FOREIGN PACKAGE MANAGERS**:
  - If the monorepo root specifies `pnpm-lock.yaml`, NEVER run `npm install`, `yarn add`, or `bun install`.
  - Adding a foreign lockfile (e.g., `package-lock.json` alongside `pnpm-lock.yaml`) breaks CI caching, leaks unsanitized hoisted packages, and corrupts local node_modules symlinks.
  - Production invariant: enforce `only-allow` in root `package.json`:
    ```json
    {
      "scripts": {
        "preinstall": "npx only-allow pnpm"
      }
    }
    ```
- **Root vs Package Dependency Segregation**:
  - **Root `package.json`**: MUST strictly contain only workspace orchestration tools and repo-wide dev tooling: `turbo`, `nx`, `typescript`, `@biomejs/biome` / `eslint`, `prettier`, `@changesets/cli`.
  - ❌ **NEVER install application runtime dependencies in the root `package.json`** (`react`, `express`, `drizzle-orm`, `@tanstack/react-query`). Application dependencies belong strictly inside the specific `apps/<app>/package.json` or `packages/<pkg>/package.json`.
  - Adding runtime packages to root causes "phantom dependency" leaks: workspace packages accidentally import root packages without declaring them in their own `package.json`, causing fatal missing module crashes when deployed in isolated containers.
- **The Workspace Protocol (`workspace:*`)**:
  - When linking internal sibling packages, ALWAYS use the `workspace:*` or `workspace:^` protocol:
    ```json
    {
      "dependencies": {
        "@acme/ui": "workspace:*",
        "@acme/database": "workspace:*",
        "@acme/config-typescript": "workspace:*"
      }
    }
    ```
  - This guarantees that package managers link the local physical folder symlink in development, and bundlers or Changesets replace `workspace:*` with the exact semver string upon external publishing.

---

## 2. Strict Package Boundary Isolation & Encapsulation
Monorepos quickly degenerate into "monolithic spaghetti" when packages reach directly into the file systems of sibling packages.

- ❌ **TOTAL BAN ON CROSS-PACKAGE DEEP PATH IMPORTS**:
  ```ts
  // ❌ Broken & Prohibited: Bypasses package exports, breaks bundling and encapsulation
  import { db } from '../../packages/database/src/client';
  import { Button } from '../../../packages/ui/src/components/button';

  // ✅ Production Invariant: Always import via the registered package name
  import { db } from '@acme/database';
  import { Button } from '@acme/ui/button';
  ```
- **Modern `package.json` `exports` Map Invariants**:
  Every internal package must explicitly declare its public API surface using conditional `exports`. Unexported files are strictly internal and inaccessible to outside packages:
  ```json
  {
    "name": "@acme/ui",
    "version": "0.1.0",
    "type": "module",
    "exports": {
      ".": {
        "types": "./dist/index.d.ts",
        "import": "./dist/index.js"
      },
      "./button": {
        "types": "./dist/button.d.ts",
        "import": "./dist/button.js"
      },
      "./package.json": "./package.json"
    },
    "scripts": {
      "build": "tsup",
      "dev": "tsup --watch"
    }
  }
  ```
- **Strict Acyclic Dependency Graph (DAG) Invariant**:
  - Circular dependencies between workspace packages (`@acme/api` -> `@acme/auth` -> `@acme/api`) corrupt build pipelines, freeze bundlers, and cause `undefined` runtime imports.
  - Enforce cyclic checks in CI via `pnpm dlx madge --circular packages/` or workspace linter rules.
  - If package A and package B need mutual types or functions, extract the common interface into a leaf utility package: `@acme/types` or `@acme/core`.

---

## 3. TypeScript Project References & Composite Compilation
The single largest cause of slow IDE response times and out-of-memory errors in monorepos is a single monolithic `tsconfig.json` attempting to typecheck the entire workspace.

- **The Project References Pattern**:
  - Each workspace package must define its own `tsconfig.json` with `composite: true` and explicit references to the packages it depends on:
    ```json
    // packages/api/tsconfig.json
    {
      "extends": "@acme/config-typescript/base.json",
      "compilerOptions": {
        "composite": true,
        "outDir": "./dist",
        "rootDir": "./src",
        "declaration": true,
        "declarationMap": true
      },
      "include": ["src"],
      "references": [
        { "path": "../database" },
        { "path": "../config" }
      ]
    }
    ```
- **`declarationMap: true` for Direct Source Navigation**:
  - ALWAYS enable `"declarationMap": true` in library packages.
  - Without declaration maps, IDE "Go to Definition" navigates to the compiled, minified `.d.ts` declaration file in `node_modules` instead of the original TypeScript source file in `packages/<pkg>/src/index.ts`.
- **Root Orchestrated Typecheck**:
  - In the workspace root, compile with composite build mode:
    ```json
    // tsconfig.json (root)
    {
      "files": [],
      "references": [
        { "path": "apps/web" },
        { "path": "apps/api" },
        { "path": "packages/ui" },
        { "path": "packages/database" }
      ]
    }
    ```
  - Execution command: `tsc --build --verbose` (or incremental `tsc -b --watch`). It builds `.tsbuildinfo` caches per package and skips recompiling unchanged packages.

---

## 4. Build Pipeline Caching & Task Graph Engineering (Turborepo & Nx)
In a monorepo with 10+ packages, running un-cached tasks destroys developer productivity. Build systems MUST execute as a directed acyclic graph (DAG) with strict input/output hashing.

- **Turborepo `turbo.json` Production Baselining**:
  ```json
  {
    "$schema": "https://turbo.build/schema.json",
    "ui": "tui",
    "tasks": {
      "topo": {
        "dependsOn": ["^topo"]
      },
      "build": {
        "dependsOn": ["^build"],
        "inputs": ["$TURBO_DEFAULT$", ".env*"],
        "outputs": [".next/**", "!.next/cache/**", "dist/**"]
      },
      "typecheck": {
        "dependsOn": ["^build"],
        "inputs": ["$TURBO_DEFAULT$"],
        "outputs": ["**/*.tsbuildinfo"]
      },
      "test": {
        "dependsOn": ["build"],
        "inputs": ["$TURBO_DEFAULT$"],
        "outputs": ["coverage/**"]
      },
      "lint": {
        "inputs": ["$TURBO_DEFAULT$"]
      },
      "dev": {
        "cache": false,
        "persistent": true
      }
    }
  }
  ```
- **Task Graph Dependency Semantics (`dependsOn`)**:
  - `"^build"` (topological dependency): This package's `build` task will only run AFTER all of its internal workspace dependencies have successfully finished their `build` task.
  - `"build"` (intra-package dependency): This package's `test` task will run only after *its own* `build` task completes.
  - Never mark non-persistent build or test tasks as `"cache": false`. If cache invalidates prematurely, inspect `inputs`.
- **Environment Variable Leakage & Cache Busting Defense**:
  - Turborepo hashes environment variables declared in `env` and `globalEnv`.
  - ❌ **The Invisible Env Trap**: Reading `process.env.NEXT_PUBLIC_API_URL` inside a package without declaring it in `turbo.json` results in remote cache hits serving builds baked with another developer's or staging's URL!
  - ✅ **Production Invariant**: Explicitly enumerate environment variables that alter build output:
    ```json
    {
      "tasks": {
        "build": {
          "env": ["NEXT_PUBLIC_API_URL", "DATABASE_URL", "NODE_ENV"]
        }
      }
    }
    ```

---

## 5. Filtered Script Execution & Agent Context Discipline
When AI agents or automation scripts operate in a monorepo, running unconstrained commands (`pnpm test`, `npm run build`) triggers builds across dozens of unrelated packages, generating thousands of lines of terminal spam that exhausts the agent context window and causes timeouts.

- **The Filtered Execution Invariant**:
  - AI agents MUST ALWAYS scope execution to the specific package or app being modified:
    ```bash
    # Run tests only for the web app and its direct workspace dependencies:
    pnpm --filter apps/web test

    # Run build for the UI package only:
    pnpm --filter @acme/ui build

    # Using Turborepo filters:
    pnpm turbo run test --filter=apps/web
    pnpm turbo run build --filter=...^@acme/api # Build all dependencies of api
    ```
- **Targeted Git-Affected Filters**:
  - In CI or pre-commit checks, verify only packages touched by recent commits:
    ```bash
    # Test only packages affected by changes compared to origin/main:
    pnpm turbo run test --filter=...[origin/main]
    ```
- **Bounded Diagnostic Truncation**:
  - If a multi-package task fails, never dump 3,000 lines of parallel output into conversation history. Use `--summarize` or filter to the failing package:
    ```bash
    pnpm turbo run build --filter=apps/web --output-logs=errors-only
    ```

---

## 6. Multi-Package Versioning & Changesets Workflow
Managing semver versions and CHANGELOG entries across dozens of interconnected workspace packages manually leads to merge conflicts and accidental breaking releases.

- **Changeset Intent-Driven Versioning**:
  - Whenever a pull request or code change touches a package's public API or implementation, generate a `.changeset/<unique-name>.md` file:
    ```bash
    pnpm changeset
    ```
  - Example changeset file (`.changeset/sweet-foxes-jump.md`):
    ```markdown
    ---
    "@acme/ui": minor
    "@acme/web": patch
    ---

    Added polymorphic `asChild` prop to Button and updated web navbar
    ```
- **Automated Version Bumping & Publishing Sequence**:
  - During release CI:
    1. `pnpm changeset version`: reads all `.changeset/*.md` files, bumps semver versions across package `package.json` files, updates respective `CHANGELOG.md` files, updates internal `workspace:*` dependency ranges, and deletes consumed changeset files.
    2. `pnpm install --no-frozen-lockfile`: updates the lockfile with newly bumped versions.
    3. `pnpm turbo run build`: generates fresh production bundles.
    4. `pnpm changeset publish`: publishes changed packages to registry with atomic npm tags and git tags.

---

## 7. Dual ESM / CJS Package Bundling Standards
When building internal or external libraries consumed across different runtimes (Next.js Node server, browser bundle, Vite, serverless Edge isolates), naive TypeScript emit creates module resolution failures.

- **Package Configuration Template with `tsup`**:
  ```ts
  // packages/utils/tsup.config.ts
  import { defineConfig } from 'tsup';

  export default defineConfig({
    entry: ['src/index.ts'],
    format: ['esm', 'cjs'],
    dts: true,
    sourcemap: true,
    clean: true,
    treeshake: true,
    splitting: false,
  });
  ```
- **Module Resolution & Target Invariants**:
  - Root `tsconfig.base.json` must enforce modern resolution standards:
    ```json
    {
      "compilerOptions": {
        "target": "ES2022",
        "module": "NodeNext",
        "moduleResolution": "NodeNext",
        "esModuleInterop": true,
        "isolatedModules": true,
        "skipLibCheck": true,
        "strict": true
      }
    }
    ```
- **Zero Drift Shared Configurations**:
  - Centralize ESLint/Biome configs (`packages/config-eslint`), TypeScript configs (`packages/config-typescript`), and Tailwind configs (`packages/config-tailwind`) as internal workspace packages rather than duplicating `.eslintrc` or `tsconfig` across every subfolder.
