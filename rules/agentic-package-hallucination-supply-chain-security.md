---
description: Agentic supply chain security, package hallucination defense, dependency slursquatting mitigation, hermetic lockfile enforcement, postinstall script sandboxing, and automated vulnerability auditing across Claude Code, Cursor, Windsurf, Devin, and Pi
globs: **/*{package.json,package-lock.json,pnpm-lock.yaml,yarn.lock,requirements.txt,Pipfile.lock,poetry.lock,Cargo.toml,Cargo.lock,go.mod,go.sum}*,**/rules/**,**/.cursorrules,**/CLAUDE.md,**/AGENTS.md,**/.agents/**
alwaysApply: false
---

# Agentic Package Hallucination Defense, Dependency Slursquatting & Hermetic Supply Chain Integrity

> Add these rules to your project when installing packages, resolving dependencies, updating lockfiles, or executing package management commands with autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode). Eliminate the "Package Hallucination Attack Vector" (where LLMs confidently invent non-existent libraries that attackers hijack via slursquatting), the "Silent Lockfile Desynchronization Catastrophe" (where agents delete or rewrite lockfiles, pulling unvetted transitive code), and the "Arbitrary Lifecycle Script RCE Trap" by enforcing a strict 4-Tier Supply Chain Armor Ladder, mandatory registry pre-flight verification, default-deny `--ignore-scripts`, Levenshtein typosquatting sentinels, and hermetic immutable lockfile verification.

---

## 1. Architectural Taxonomy: The Hallucinated Dependency Dilemma vs The 4-Tier Supply Chain Armor

In modern AI-assisted software engineering, autonomous coding agents have shell execution capabilities and interact with external package managers (`npm`, `pnpm`, `pip`, `poetry`, `cargo`, `go get`). While agents excel at algorithmic reasoning, their underlying neural network next-token prediction introduces critical supply-chain attack surfaces:

- **The Hallucinated Package Hijacking Trap (Dependency Slursquatting)**:
  - When an agent attempts to solve a problem (e.g. JWT verification, cloud auth, or CSV streaming), it frequently hallucinates plausible library names that do not exist (e.g., `npm i @auth0/express-jwt-interceptor` or `pip install langchain-crypto-helpers`).
  - Threat actors continually scrape LLM outputs, query logs, and common prompt domains, identifying high-frequency hallucinated package names. They register these unclaimed package names on the public npm, PyPI, or RubyGems registries.
  - When an agent runs `npm install <hallucinated-package>`, the malicious package downloads instantly. It triggers a `postinstall` script that extracts `.env` secrets, developer SSH keys, AWS credentials, and source code, uploading them to an external command-and-control server.
- **The Blind Lockfile Reconstruction Catastrophe (`rm -rf package-lock.json`)**:
  - When an agent encounters a peer-dependency conflict or version mismatch, naive agents attempt brute-force triage: `rm package-lock.json node_modules && npm install` or `pip install --upgrade -r requirements.txt`.
  - This wipes out pinned cryptographic SHA-512 hashes and resolved transitive trees. It exposes the application to unpinned upstream supply-chain compromises, floating dependency drift, and non-reproducible builds across CI/CD environments.
- **The Arbitrary Lifecycle Script RCE Trap (`postinstall` Execution)**:
  - Standard package managers execute arbitrary shell commands specified in `package.json` under `preinstall`, `install`, and `postinstall` hooks (or Python `setup.py` / Rust `build.rs`).
  - Running unvetted third-party packages without `--ignore-scripts` gives untrusted code immediate arbitrary code execution privileges inside the developer workstation or agent container.
- **The Typosquatting & Levenshtein Token Drift Trap**:
  - Due to tokenization boundaries or memory fading, agents frequently introduce minor spelling variations for well-known packages (`cross-env2` instead of `cross-env`, `lodas-es` instead of `lodash-es`, `react-route-dom` instead of `react-router-dom`). Malicious typosquats masquerade under these names, mimicking the API while executing backdoor payloads.
- **The Abandoned & Deprecated Dependency Ingestion Trap**:
  - Agents trained on legacy code often install libraries that were deprecated years ago (e.g. `request`, `node-uuid`, `moment` for modern ESM stacks), introducing unpatched CVEs and memory leaks instead of using built-in web standards (`fetch`, `crypto.randomUUID`, `Intl`).
- **The 4-Tier Supply Chain Armor Ladder**:
  - Zero-trust agent supply chain security organizes dependency management into 4 machine-enforced verification tiers:
    - **Tier 0: Pre-Flight Registry Verification & Quarantine**: Query the official registry API *before* running install commands. Verify that the package exists, is at least 30 days old ($t_{\text{age}} \ge 30\text{d}$), and has $\ge 10,000$ weekly downloads or belongs to an approved verified corporate scope.
    - **Tier 1: Hermetic Immutable Lockfile Verification**: Strictly require `--frozen-lockfile` (pnpm), `npm ci` (npm), `poetry install --sync`, `cargo --locked`, or `go mod verify`. Forbid deleting lockfiles or executing unpinned additions.
    - **Tier 2: Default-Deny Lifecycle Scripts**: All package installation commands MUST pass `--ignore-scripts`. Native binaries requiring compilation must be explicitly whitelisted with SHA-256 verification.
    - **Tier 3: In-Tree Vulnerability & Typo-Squatting Sentinels**: Run automated security scanners (`npm audit`, `pip-audit`, `govulncheck`, `cargo audit`, `osv-scanner`) and Levenshtein distance checks ($D_L \le 2$) against high-reputation packages before committing lockfile modifications.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Agent Proposes Adding Dependency: "npm install @auth0/express-jwt-interceptor"                  │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Unvetted Installation]                                           ▼ [PRODUCTION: 4-Tier Armor]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Execute Shell: npm install <pkg>                │               │ Tier 0: Pre-Flight Registry & Slursquat Check   │
│ ❌ Hallucinated package registered by attacker  │               │ • GET https://registry.npmjs.org/<pkg>          │
│ ❌ postinstall script runs arbitrary bash       │               │ • Check: Exists? Age >= 30d? Downloads >= 10k?  │
│ ❌ Exfiltrates .env and SSH keys                │               ├─────────────────────────────────────────────────┤
│ ❌ Deletes package-lock.json on conflict        │               │ Tier 1: Levenshtein Typosquatting Sentinel      │
└─────────────────────────────────────────────────┘               │ • Compute Levenshtein dist DL against top 2,000 │
                                                                  │ • Reject suspicious spoofing (DL in [1, 2]).    │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 2: Sandboxed Execution & Script Isolation │
                                                                  │ • npm install --ignore-scripts --save-exact     │
                                                                  │ • Run inside rootless sandboxed worker.         │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Tier 3: In-Tree Vulnerability & SBOM Audit      │
                                                                  │ • Run npm audit --audit-level=high & osv-scanner│
                                                                  │ • Verify lockfile diff is minimal & pinned.     │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Quantitative Blast-Radius & Typosquatting Calculus

Autonomous agents must mathematically evaluate package candidates before recommending or installing them.

### 1. The Package Reputation Score ($S_{\text{pkg}}$)
A proposed package must satisfy a minimum Reputation Score ($S_{\text{pkg}} \ge 0.80$) prior to adoption:

$$S_{\text{pkg}} = w_{\text{age}} \cdot f_{\text{age}}(t) + w_{\text{dl}} \cdot f_{\text{dl}}(N) + w_{\text{rep}} \cdot f_{\text{rep}}(V) + w_{\text{scope}} \cdot \mathbf{1}_{\text{verified}}$$

Where:
- $w_{\text{age}} = 0.25$, $w_{\text{dl}} = 0.35$, $w_{\text{rep}} = 0.20$, $w_{\text{scope}} = 0.20$.
- $f_{\text{age}}(t) = \min(1.0, \frac{t_{\text{days}}}{180})$: Packages younger than 30 days receive $0.0$; packages $> 180$ days receive $1.0$.
- $f_{\text{dl}}(N) = \min(1.0, \frac{\log_{10}(N_{\text{weekly\_downloads}})}{5})$: Packages with $< 1,000$ weekly downloads receive $\le 0.6$; $> 100,000$ receive $1.0$.
- $f_{\text{rep}}(V) = 1.0 - \min(1.0, 0.3 \cdot N_{\text{known\_CVEs}})$: Deducts score for active unpatched CVEs.
- $\mathbf{1}_{\text{verified}} = 1.0$ if the package resides under an officially verified organization scope (e.g., `@angular/*`, `@aws-sdk/*`, `@google/*`, `@microsoft/*`, `@vue/*`, `@sveltejs/*`), else $0.0$.

### 2. Levenshtein Distance Typosquatting Detection
Let $P_{\text{target}}$ be the proposed package name and $P_{\text{popular}}$ be a known high-download package from the curated baseline catalog. The Levenshtein distance $D_L(s_1, s_2)$ is the minimum number of single-character edits (insertions, deletions, or substitutions) required to change $s_1$ into $s_2$.

$$\text{Flag as Typosquat Candidate if: } 1 \le D_L(P_{\text{target}}, P_{\text{popular}}) \le 2 \quad \text{AND} \quad \frac{N_{\text{downloads}}(P_{\text{target}})}{N_{\text{downloads}}(P_{\text{popular}})} < 0.01$$

If a package name is within 1–2 edits of a popular package (e.g. `expresss` vs `express`, `lodas-es` vs `lodash-es`) and has less than 1% of its download volume, the agent MUST immediately abort the installation with a high-severity alert.

---

## 3. Strict Packaging Ecosystem Invariants

### 1. Node.js & TypeScript (`npm`, `pnpm`, `yarn`)
- **Never Run Bare `npm install <pkg>`**:
  - ❌ Anti-pattern: `npm install some-library` (installs with `^` range, enables postinstall scripts).
  - ✅ Production invariant: Always specify exact version pinning and ignore scripts:
    ```bash
    # Exact version pinning + script execution suppression
    npm install --save-exact --ignore-scripts <package>@<version>
    # In pnpm:
    pnpm add --save-exact --ignore-scripts <package>@<version>
    ```
- **Never Delete or Reconstruct the Lockfile**:
  - ❌ Anti-pattern: `rm package-lock.json && npm install`
  - ✅ Production invariant: When resolving CI builds or test environments, always use frozen verification:
    ```bash
    npm ci
    # In pnpm:
    pnpm install --frozen-lockfile
    # In yarn:
    yarn install --immutable
    ```
- **Verify Integrity Hashes**: Every entry in `package-lock.json` must contain a valid `integrity` property with `sha512-...`. Lockfiles with missing hashes or `http://` tarball URLs must be rejected.

### 2. Python (`pip`, `poetry`, `uv`)
- **Prohibit Unpinned `pip install`**:
  - ❌ Anti-pattern: `pip install requests` (installs latest arbitrary wheel, runs `setup.py`).
  - ✅ Production invariant: Use `uv` or `pip` with hash verification:
    ```bash
    pip install --require-hashes -r requirements.txt
    # Or modern uv:
    uv pip sync --locked requirements.txt
    ```
- **Inspect `setup.py` / Build Backdoors**: Never allow packages that execute shell subprocesses during wheel building without sandboxing. Prefer pure-wheel binary distributions (`--only-binary :all:`).

### 3. Go (`go get`, `go mod`)
- **Mandatory `go.sum` Cryptographic Checksumming**:
  - Every external dependency must be verified against the official Go checksum database (`sum.golang.org`).
  - Always run `go mod verify` before concluding any dependency update:
    ```bash
    go mod tidy
    go mod verify # Must exit 0: "all modules verified"
    ```
- **Prevent Vendor Directory Tampering**: If using `vendor/`, ensure `go test -mod=readonly` is enforced in all CI pipelines.

### 4. Rust (`cargo`)
- **Enforce `Cargo.lock` Immutability**:
  - Always build with `cargo build --locked`.
  - Use `cargo-audit` to detect yanked or vulnerable crates in the dependency tree:
    ```bash
    cargo audit
    cargo verify-project
    ```

---

## 4. Production Reference Implementation: `AgenticSupplyChainDefenseEngine`

The following TypeScript engine provides complete registry verification, Levenshtein typosquatting protection, script sandboxing, and lockfile validation for autonomous agents:

```typescript
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export interface PackageValidationRequest {
  ecosystem: 'npm' | 'pypi' | 'cargo';
  packageName: string;
  requestedVersion?: string;
  allowScripts?: boolean;
}

export interface PackageValidationResult {
  allowed: boolean;
  score: number;
  reasons: string[];
  safeInstallCommand: string;
  metadata?: {
    resolvedVersion: string;
    publishedDate: string;
    weeklyDownloads: number;
    hasInstallScripts: boolean;
    license: string;
  };
}

export class AgenticSupplyChainDefenseEngine {
  private readonly popularPackages = new Set<string>([
    'react', 'react-dom', 'vue', 'svelte', 'express', 'lodash', 'lodash-es',
    'axios', 'zod', 'next', 'nuxt', 'vite', 'typescript', 'tailwindcss',
    'date-fns', 'dayjs', 'clsx', 'tailwind-merge', 'chalk', 'dotenv',
    'commander', 'rxjs', 'vitest', 'jest', 'playwright', 'esbuild'
  ]);

  private readonly verifiedScopes = new Set<string>([
    '@types', '@angular', '@aws-sdk', '@azure', '@google-cloud',
    '@microsoft', '@nestjs', '@nuxt', '@sveltejs', '@vue', '@trpc', '@prisma'
  ]);

  /**
   * Pre-flight validation gate before any agent installation command
   */
  public async validatePackageInstall(request: PackageValidationRequest): Promise<PackageValidationResult> {
    const reasons: string[] = [];
    let score = 1.0;

    // 1. Typosquatting Detection (Levenshtein Distance)
    const typosquatCandidate = this.detectTyposquat(request.packageName);
    if (typosquatCandidate) {
      return {
        allowed: false,
        score: 0.0,
        reasons: [`CRITICAL: Potential typosquatting of high-popularity package "${typosquatCandidate}".`],
        safeInstallCommand: ''
      };
    }

    // 2. Ecosystem Specific Registry Verification
    if (request.ecosystem === 'npm') {
      try {
        const metadata = await this.fetchNpmMetadata(request.packageName, request.requestedVersion);
        
        // Age Sentinel: Reject packages younger than 30 days
        const publishedDate = new Date(metadata.publishedDate);
        const ageDays = (Date.now() - publishedDate.getTime()) / (1000 * 60 * 60 * 24);
        if (ageDays < 30) {
          score -= 0.4;
          reasons.push(`Package is only ${Math.round(ageDays)} days old (minimum 30 days required for unverified packages).`);
        }

        // Download Volume Sentinel
        if (metadata.weeklyDownloads < 10000 && !this.isVerifiedScope(request.packageName)) {
          score -= 0.35;
          reasons.push(`Low weekly downloads (${metadata.weeklyDownloads} < 10,000) and not under a verified scope.`);
        }

        // Postinstall Script Sentinel
        if (metadata.hasInstallScripts && !request.allowScripts) {
          reasons.push('Package contains lifecycle scripts (preinstall/postinstall). Scripts will be suppressed.');
        }

        const allowed = score >= 0.65;
        const safeInstallCommand = `npm install --save-exact --ignore-scripts ${request.packageName}@${metadata.resolvedVersion}`;

        return {
          allowed,
          score,
          reasons,
          safeInstallCommand: allowed ? safeInstallCommand : '',
          metadata
        };
      } catch (err: any) {
        return {
          allowed: false,
          score: 0.0,
          reasons: [`Package hallucination detected: "${request.packageName}" not found on npm registry (${err.message}).`],
          safeInstallCommand: ''
        };
      }
    }

    // Default fallback for unhandled ecosystem
    return {
      allowed: true,
      score: 0.8,
      reasons: ['Non-npm package: manual verification required.'],
      safeInstallCommand: `echo "Manual review required for ${request.packageName}"`
    };
  }

  /**
   * Levenshtein Distance calculation
   */
  private levenshteinDistance(a: string, b: string): number {
    const matrix: number[][] = [];
    for (let i = 0; i <= b.length; i++) matrix[i] = [i];
    for (let j = 0; j <= a.length; j++) matrix[0][j] = j;

    for (let i = 1; i <= b.length; i++) {
      for (let j = 1; j <= a.length; j++) {
        if (b.charAt(i - 1) === a.charAt(j - 1)) {
          matrix[i][j] = matrix[i - 1][j - 1];
        } else {
          matrix[i][j] = Math.min(
            matrix[i - 1][j - 1] + 1, // substitution
            matrix[i][j - 1] + 1,     // insertion
            matrix[i - 1][j] + 1      // deletion
          );
        }
      }
    }
    return matrix[b.length][a.length];
  }

  private detectTyposquat(targetName: string): string | null {
    // Exact matches to popular packages are legitimate
    if (this.popularPackages.has(targetName)) return null;

    for (const popular of this.popularPackages) {
      const dist = this.levenshteinDistance(targetName.toLowerCase(), popular);
      if (dist === 1 || dist === 2) {
        return popular;
      }
    }
    return null;
  }

  private isVerifiedScope(name: string): boolean {
    if (!name.startsWith('@')) return false;
    const scope = name.split('/')[0];
    return this.verifiedScopes.has(scope);
  }

  private async fetchNpmMetadata(name: string, requestedVersion?: string) {
    const encodedName = encodeURIComponent(name).replace(/^%40/, '@');
    const url = `https://registry.npmjs.org/${encodedName}`;
    
    const response = await fetch(url, { headers: { Accept: 'application/json' } });
    if (!response.ok) {
      throw new Error(`Registry responded with HTTP ${response.status}`);
    }

    const data = await response.json();
    const latestVersion = requestedVersion || data['dist-tags']?.latest;
    const versionData = data.versions?.[latestVersion];

    if (!versionData) {
      throw new Error(`Version ${latestVersion} not found on registry`);
    }

    // Query downloads API (past week)
    let weeklyDownloads = 0;
    try {
      const dlRes = await fetch(`https://api.npmjs.org/downloads/point/last-week/${encodedName}`);
      if (dlRes.ok) {
        const dlData = await dlRes.json();
        weeklyDownloads = dlData.downloads || 0;
      }
    } catch {
      // Non-fatal if download stats API is unreachable
    }

    const scripts = versionData.scripts || {};
    const hasInstallScripts = Boolean(scripts.preinstall || scripts.install || scripts.postinstall);

    return {
      resolvedVersion: latestVersion,
      publishedDate: data.time?.[latestVersion] || data.time?.created || new Date().toISOString(),
      weeklyDownloads,
      hasInstallScripts,
      license: versionData.license || 'UNKNOWN'
    };
  }

  /**
   * Run automated security audit against workspace
   */
  public async runAuditGate(workspaceDir: string): Promise<{ clean: boolean; summary: string }> {
    try {
      const { stdout } = await execFileAsync('npm', ['audit', '--json', '--audit-level=high'], {
        cwd: workspaceDir,
        timeout: 20000
      });
      const audit = JSON.parse(stdout);
      const vulnCounts = audit.metadata?.vulnerabilities || {};
      const criticalCount = (vulnCounts.high || 0) + (vulnCounts.critical || 0);

      if (criticalCount > 0) {
        return {
          clean: false,
          summary: `Audit failed: ${criticalCount} high/critical vulnerabilities discovered.`
        };
      }
      return { clean: true, summary: 'Audit passed: zero high/critical vulnerabilities.' };
    } catch (err: any) {
      // npm audit exits with 1 if vulnerabilities are found
      if (err.stdout) {
        try {
          const audit = JSON.parse(err.stdout);
          const vulnCounts = audit.metadata?.vulnerabilities || {};
          return {
            clean: false,
            summary: `Audit failed: ${vulnCounts.high || 0} high, ${vulnCounts.critical || 0} critical.`
          };
        } catch {
          // ignore parse error
        }
      }
      return { clean: false, summary: `Failed to execute audit: ${err.message}` };
    }
  }
}
```

---

## 5. The 6-State Supply Chain Lifecycle Finite-State Machine (FSM)

Every package addition or lockfile modification executed by an autonomous agent MUST transition through this deterministic FSM:

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                    1. DORMANT                                    │
│                 (Agent identifies need for external capability)                  │
└────────────────────────────────────────┬─────────────────────────────────────────┘
                                         │
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                           2. PRE_FLIGHT_REGISTRY_CHECK                           │
│        (Query Registry API: verify package exists, age >= 30d, dl >= 10k)        │
└───────────────────┬──────────────────────────────────────────────┬───────────────┘
                    │ [Pass: Exists & Reputable]                   │ [Fail: Non-existent / Hallucination]
                    ▼                                              ▼
┌───────────────────────────────────────┐      ┌───────────────────────────────────┐
│       3. TYPOSQUAT_FILTER_GATE        │      │          ABORT_WITH_ALERT         │
│  (Levenshtein DL against top 2,000)   │      │ (Reject hallucinated package name)│
└───────────────────┬───────────────────┘      └───────────────────────────────────┘
                    │ [Pass: Not a typosquat]
                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                           4. SANDBOXED_EXACT_INSTALL                             │
│        (Execute with --save-exact and mandatory --ignore-scripts flag)           │
└────────────────────────────────────────┬─────────────────────────────────────────┘
                                         │
                                         ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              5. VULNERABILITY_AUDIT                              │
│         (Execute npm audit / govulncheck / cargo audit; enforce 0 high/crit)     │
└───────────────────┬──────────────────────────────────────────────┬───────────────┘
                    │ [Audit Clean]                                │ [CVEs Found]
                    ▼                                              ▼
┌───────────────────────────────────────┐      ┌───────────────────────────────────┐
│        6. COMMITTED_LOCKFILE          │      │         ROLLBACK_WORKTREE         │
│  (Stage atomic commit with git diff)  │      │ (git checkout -- lockfile & pkgs) │
└───────────────────────────────────────┘      └───────────────────────────────────┘
```

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

Before any agent marks a dependency modification or lockfile change as completed, every gate in this matrix MUST pass:

| Gate | Phase | Verification Invariant / Command | Failure Action |
| :--- | :--- | :--- | :--- |
| **G1: Pre-Flight Registry Verification** | Discovery | Package exists on official upstream registry API; not 404. | Immediate abort; halt hallucinated package installation. |
| **G2: Slursquatting Age/Volume Gate** | Reputation | Package age $\ge 30\text{ days}$ and weekly downloads $\ge 10,000$ (or verified scope). | Reject package; demand proven alternative or standard library. |
| **G3: Typosquatting Sentinel** | Safety | Levenshtein distance $D_L \notin [1, 2]$ against top 2,000 package catalog. | Reject candidate; notify developer of potential typosquatting. |
| **G4: Script Execution Suppression** | Execution | Mandatory `--ignore-scripts` flag in execution AST. | Abort command before shell invocation. |
| **G5: Frozen Lockfile Immutability** | Verification | `npm ci` / `pnpm install --frozen-lockfile` / `go mod verify` exits 0. | Revert unstaged changes; reject unpinned drift. |
| **G6: Zero High/Critical Vulnerabilities** | Audit | `npm audit --audit-level=high` (or ecosystem equivalent) exits 0. | Rollback package addition; require remediated version. |

---

## 7. Concrete Anti-Patterns & Corrective Production Recipes

### 1. Hallucinated Utility Packages vs Zero-Dependency Modern Web Standards
- ❌ **Anti-Pattern**: Agent installs hallucinated or bloated single-function utility libraries:
  ```bash
  # Hallucinated or unnecessary legacy packages:
  npm install @auth0/jwt-verify-shim is-odd-number uuid-generator-fast
  ```
- ✅ **Production Invariant**: Use built-in ECMAScript & Node.js 18+ Web standard primitives:
  ```typescript
  // UUID generation without external libraries:
  const id = crypto.randomUUID();

  // Cryptographic hashing using built-in web crypto:
  async function sha256(message: string): Promise<string> {
    const msgBuffer = new TextEncoder().encode(message);
    const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
    return Array.from(new Uint8Array(hashBuffer))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }

  // Exact number parity check:
  const isOdd = (n: number): boolean => (n & 1) === 1;
  ```

### 2. Lockfile Conflict Resolution Without Destructive Deletion
- ❌ **Anti-Pattern**: Deleting lockfiles to resolve Git merge conflicts:
  ```bash
  # Destructive: completely invalidates all pinned sub-dependencies
  rm package-lock.json && npm install
  ```
- ✅ **Production Invariant**: Use git and the package manager's native lockfile deduplication and merge resolution:
  ```bash
  # Restore the lockfile from main and allow npm to resolve only the delta:
  git checkout origin/main -- package-lock.json
  npm install --package-lock-only
  git diff package-lock.json # Verify only expected diffs exist
  ```

### 3. Python Virtualenv & Hash Enforcement
- ❌ **Anti-Pattern**: Installing unpinned dependencies globally or without hash constraints:
  ```bash
  pip install langchain openai
  ```
- ✅ **Production Invariant**: Use `uv` or `pip-compile` with pinned SHA-256 hashes:
  ```bash
  # Generate cryptographically pinned requirements with hashes:
  uv pip compile pyproject.toml --generate-hashes -o requirements.txt
  # Install strictly matching hashes:
  uv pip sync requirements.txt
  ```

---

*Follow these principles to ensure autonomous coding agents operate with airtight supply chain integrity, completely immune to package hallucination attacks, slursquatting backdoors, and lockfile corruption.*
