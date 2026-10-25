---
description: Agentic code intelligence, repository-scale AST indexing, Tree-sitter symbol graphs, PageRank repository maps (Aider style), surgical search/replace patching, blast radius dependency analysis, closed-loop compiler/test verification, and SWE-bench execution harnesses
globs: **/*{repo,ast,treesitter,indexer,parser,patch,diff,edit,code_intelligence,swe}*.*,**/indexer/**,**/parser/**,**/tools/edit*.*,**/tools/patch*.*,**/swe/**
alwaysApply: false
---

# Agentic Code Intelligence, Repository Maps, Tree-sitter AST & Surgical Editing Invariants

> Add these rules to your project when architecting, implementing, or auditing AI coding agents, repository indexers, AST symbol analyzers, patch/diff generation engines, or SWE-bench automated software engineering harnesses (Claude Code, Cursor, Windsurf, Aider, OpenCode, Devon, Pi).

---

## 1. Architectural Taxonomy: Repository-Scale Intelligence vs Naive Context Flooding

Software repositories frequently span hundreds of thousands to millions of lines of code. Naively dumping entire files into an LLM context window triggers the **Context Flooding Anti-Pattern**: extreme token costs, slow inference latency, massive KV cache thrashing, and "Lost-in-the-Middle" hallucinations where the model invents non-existent APIs or overlooks critical invariants.

Autonomous coding agents require a **Hierarchical Code Navigation Architecture**:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                              User Mission / Bug Ticket / Feature Spec                  │
│                     ("Refactor Auth token validation to support Ed25519 keys")          │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 1. Global Repository Map (Level 0: ~1,024 – 4,096 tokens)                              │
│    • High-density symbol topology generated via AST extraction & PageRank.             │
│    • Shows only critical exported types, structs, interfaces, and function signatures. │
│    • Identifies relevant modules without reading implementation source lines.          │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 2. Blast Radius & Dependency Tracing (Level 1: Focused AST Slices)                     │
│    • Identifies definitions (def) and all referencing call sites (ref).                │
│    • Computes transitive impact: which downstream files break if an interface changes?  │
│    • Slices target files to relevant symbol declarations + docstrings.                 │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 3. Surgical File Windows (Level 2: Targeted Reading)                                   │
│    • Agent reads ONLY the target file regions with 10–20 lines of contextual padding.  │
│    • Verifies fresh file SHA-256 hash to prevent stale-buffer race conditions.          │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 4. Surgical Patch Generation (Search / Replace Blocks)                                 │
│    • Agent emits minimal SEARCH / REPLACE blocks instead of rewriting entire files.   │
│    • Multi-pass fuzzy matcher resolves whitespace, CRLF, and indentation shifts.      │
│    • Pre-flight Tree-sitter parse validates AST validity before writing to disk.       │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 5. Closed-Loop Verification Harness (The SWE-bench Gatekeeper)                          │
│                                                                                        │
│    [Patched Files] ──▶ [Gate 1: AST Syntax] ──▶ [Gate 2: Typecheck] ──▶ [Gate 3: Tests]│
│            ▲                   │                       │                      │        │
│            │ Fail              ▼ Fail                  ▼ Fail                 ▼ Fail   │
│            └────────── [Single-Turn Self-Correction with Exact Compiler Error Trace]   │
│                                                                                        │
│                                           │ All Gates Green                            │
│                                           ▼                                            │
│                        [Atomic Commit / Push Pull Request]                             │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. AST Extraction & Symbol Dependency Graphs via Tree-sitter

- ❌ **THE NAIVE REGEX & LINE-CHUNKING ANTI-PATTERN**:
  - Splitting source files by arbitrary line counts (e.g. 100 lines) or naive regexes (`/^function /`) breaks code across semantic boundaries (splitting a method body from its type annotations or opening braces).
  - Regexes fail on multi-line parameter lists, nested generics, conditional exports, and decorators.
- ✅ **PRODUCTION INVARIANT: Tree-sitter Concrete Syntax Trees (CST)**:
  - Parse every supported language using native Tree-sitter grammars (or robust language parsers) into an Abstract Syntax Tree.
  - Distinguish between **Definitions** (where an identifier is declared/exported) and **References** (where an identifier is invoked/consumed).

### Multi-Language Symbol Extraction Queries (Tree-sitter S-Expressions)

| Language | Definition S-Expression Pattern | Extracted Symbol Attributes |
| :--- | :--- | :--- |
| **TypeScript / JS** | `(function_declaration name: (identifier) @name)`<br>`(class_declaration name: (type_identifier) @name)`<br>`(interface_declaration name: (type_identifier) @name)`<br>`(export_statement declaration: (_) @decl)` | Identifier, exported flag, parameter types, return type, docstring |
| **Go** | `(function_declaration name: (identifier) @name)`<br>`(method_declaration receiver: (parameter_list) name: (field_identifier) @name)`<br>`(type_declaration (type_spec name: (type_identifier) @name type: (_)))` | Identifier, receiver type, exported (title-cased), signatures |
| **Python** | `(function_definition name: (identifier) @name)`<br>`(class_definition name: (identifier) @name)` | Identifier, parameters, return type annotations, docstrings |
| **Rust** | `(function_item name: (identifier) @name)`<br>`(struct_item name: (type_identifier) @name)`<br>`(enum_item name: (type_identifier) @name)`<br>`(trait_item name: (type_identifier) @name)` | Identifier, visibility (`pub`), generic params, trait bounds |

```ts
// Production Invariant: Symbol Extraction Data Model
export interface AstSymbol {
  name: string;
  kind: 'function' | 'method' | 'class' | 'interface' | 'type' | 'struct' | 'enum' | 'variable';
  filePath: string;
  range: {
    startLine: number; // 1-indexed
    startCol: number;
    endLine: number;
    endCol: number;
  };
  signature: string;       // e.g. "export async function verifyToken(raw: string): Promise<TokenPayload>"
  docstring?: string;      // JSDoc, Go doc, Python docstring
  isExported: boolean;
  references: string[];    // Identifiers referenced within this symbol's body
}
```

---

## 3. The PageRank Repository Map Algorithm (Aider Math & Topology)

When an agent begins a task, it must understand the global codebase architecture within a strictly budgeted token window (typically 1,024 to 4,096 tokens). The industry standard is the **PageRank-Biased Repository Map**.

### Mathematical Formulation
1. Construct a directed multigraph $G = (V, E)$:
   - **Nodes ($V$)**: Every source file in the repository.
   - **Directed Edges ($E$)**: An edge exists from file $u$ to file $v$ ($u \to v$) if file $u$ references a symbol defined and exported by file $v$.
   - **Edge Weight ($W(u, v)$)**: The frequency of references between $u$ and $v$, inversely scaled by common identifier stopwords (e.g. `err`, `data`, `id`).

2. Compute Personalized PageRank (PPR) over graph $G$:
   $$PR(u) = (1 - \alpha) \cdot p(u) + \alpha \sum_{v \in \mathcal{N}_{\text{in}}(u)} PR(v) \frac{W(v, u)}{\sum_{w} W(v, w)}$$
   - $\alpha \approx 0.85$ (damping factor).
   - $p(u)$ is the personalization/teleportation vector:
     - Uniform across all files during cold-start discovery: $p(u) = \frac{1}{|V|}$.
     - **Query-Biased**: Biased towards files explicitly mentioned in the user prompt or currently opened in active editor tabs.

3. **Greedy Token-Budget Packing**:
   - Sort files by descending $PR(u)$.
   - For each file, format its extracted AST definitions into a condensed signature-only tree.
   - Greedily append signatures into the repository map buffer until the hard token ceiling (e.g., 2,500 tokens) is reached. Truncate low-ranking implementation details first.

```markdown
<!-- Production Invariant: Condensed Level 0 Repository Map Format -->
agent-arsenal/
├── src/auth/
│   ├── jwt.ts
│   │   ├── export interface TokenPayload { userId: string; role: Role; exp: number }
│   │   └── export function verifyJwt(token: string, key: CryptoKey): Promise<TokenPayload>
│   └── session.ts
│       └── export class SessionStore
│           ├── constructor(redis: RedisClient)
│           ├── get(id: string): Promise<Session | null>
│           └── set(session: Session, ttlMs: number): Promise<void>
└── src/crypto/
    └── ed25519.ts
        ├── export function generateKeyPair(): Promise<KeyPair>
        └── export function signDetached(msg: Uint8Array, privKey: Uint8Array): Uint8Array
```

---

## 4. Surgical Editing Disciplines: Search/Replace vs Unified Diff vs Whole File

- ❌ **ANTI-PATTERN 1: THE WHOLE-FILE OVERWRITE CATASTROPHE**:
  - Requiring the LLM to reproduce a 1,000-line file just to modify 3 lines.
  - Causes severe token consumption, slow completions ($>30\text{s}$), random completions truncation (`max_tokens` reached mid-file), and accidental deletion of untouched helper functions or comments.
- ❌ **ANTI-PATTERN 2: RAW UNIFIED DIFF FRAGILITY**:
  - LLMs frequently hallucinate line offset counts in unified diff headers (`@@ -142,8 +142,10 @@`).
  - Standard POSIX `patch` fails with `hunk #1 FAILED at line 142` because LLMs cannot calculate exact zero-indexed character offsets while autoregressively streaming tokens.
- ✅ **PRODUCTION INVARIANT: SEARCH / REPLACE BLOCKS**:
  - Agents MUST emit discrete, contextual Search/Replace blocks.
  - Every SEARCH block must provide sufficient surrounding context (typically 3–5 lines before and after) to guarantee uniqueness within the file.

```
<<<<<<< SEARCH
function validateUser(id: string): boolean {
  return id.length > 0;
}
=======
function validateUser(id: string): boolean {
  if (!id || id.trim().length === 0) {
    return false;
  }
  return UUID_V4_REGEX.test(id);
}
>>>>>>> REPLACE
```

### The 4-Tier Tolerant Patch Engine Algorithm
When applying a SEARCH block against disk source:

1. **Pass 1: Exact Bit-for-Bit Match**:
   - Locate the exact character sequence of the SEARCH block in the target file.
   - If found **exactly once**, apply the replacement immediately.
   - If found **multiple times**, reject the patch: *Ambiguous match: SEARCH block matches $N$ locations. Provide more contextual lines.*

2. **Pass 2: Whitespace & Line-Ending Normalization (CRLF vs LF)**:
   - Normalize `\r\n` to `\n` in both candidate and target buffers.
   - Strip trailing whitespace on each line. If a unique match occurs, apply replacement preserving the target file's original line endings.

3. **Pass 3: Indentation-Agnostic Matching**:
   - Compute common leading indentation of the SEARCH block.
   - Match line content while allowing variable indent shifts (e.g. 2 spaces vs 4 spaces vs tabs).
   - Re-indent the REPLACE block to align with the detected target file indentation.

4. **Pass 4: Levenshtein / Fuzzy Subsequence Matching (Max Distance Threshold $\le 3$)**:
   - If minor punctuation or single-word formatting changed, locate candidate window with Levenshtein similarity $\ge 95\%$.
   - Apply only if the candidate window is uniquely identifiable and confidence is above 0.98. Otherwise, reject.

---

## 5. Pre-Commit AST Syntax Validation & Atomic Writes

- ❌ **THE BLIND DISK WRITE ANTI-PATTERN**:
  - Writing patched file contents directly to disk without parsing. A single missing closing bracket or semicolon breaks the user's running dev server or compiler immediately.
- ✅ **PRODUCTION INVARIANT: PRE-COMMIT AST CHECK & ATOMIC WRITE**:
  1. Apply the candidate patch in an in-memory buffer.
  2. Parse the resulting buffer using the language's Tree-sitter parser or native compiler dry-run.
  3. If syntax errors exist (e.g. `ERROR` nodes in Tree-sitter CST), **abort write**, reject the patch, and return the exact syntax error line to the LLM for immediate self-correction.
  4. Write to disk **atomically**: write to a temporary file in the same directory (`.target.ts.tmp.PID`), `fsync` the file descriptor, and perform an atomic `rename` (`fs.renameSync`). This prevents half-written files if the agent process is terminated mid-write.

---

## 6. Blast Radius Analysis & Cross-File Dependency Propagation

When an agent refactors an exported interface, method signature, or database model, changing only the declaration file creates silent breakages across downstream consumers.

```
                  ┌──────────────────────────────┐
                  │    Target Mutation File      │
                  │   src/auth/token.ts (def)    │
                  └──────────────┬───────────────┘
                                 │
                 Changed: verifyToken(token, key)
                 Added param: options: VerifyOpts
                                 │
         ┌───────────────────────┴───────────────────────┐
         ▼                                               ▼
┌──────────────────────────────┐         ┌──────────────────────────────┐
│       Downstream File A      │         │       Downstream File B      │
│  src/api/middleware.ts (ref) │         │   tests/auth.test.ts (ref)   │
│  Status: Signature Broken ❌ │         │  Status: Signature Broken ❌ │
└──────────────────────────────┘         └──────────────────────────────┘
```

- **Blast Radius Invariants**:
  1. **Identify Modified Exports**: Inspect the AST diff between original and patched files. List all exported identifiers whose signatures changed.
  2. **Query the Symbol Graph**: For every modified exported symbol, retrieve all inbound references ($v \to \text{target}$).
  3. **Multi-File Refactoring Plan**: The agent must not report completion until all downstream call sites are either updated in the same changeset or verified as compatible.

---

## 7. The SWE-bench Closed-Loop Verification Pipeline

Autonomous coding agents must adhere to the **5-Gate Quality Funnel** before presenting a code change for human review or merging:

```
[Candidate Code Patch]
        │
        ▼
[Gate 1: AST Syntax Validation] ────────── Fail ──▶ [Auto-Repair: Syntax Diagnostics]
        │ Pass (<50ms)
        ▼
[Gate 2: Static Typecheck / Dry-Run] ───── Fail ──▶ [Auto-Repair: Compiler Error Output]
        │ (tsc --noEmit / go vet / cargo check)
        ▼
[Gate 3: Linter & Format Conformance] ─── Fail ──▶ [Auto-Format: prettier / ruff / gofmt]
        │ Pass (<5s)
        ▼
[Gate 4: Targeted Unit Tests] ──────────── Fail ──▶ [Auto-Repair: Test Assertion Trace]
        │ (Run ONLY tests covering touched symbols)
        ▼
[Gate 5: Full Regression Suite] ───────── Fail ──▶ [Revert to Git Checkpoint]
        │ Pass
        ▼
[Verified Commit Ready]
```

### Self-Correction Error Turn Invariant
When Gates 1, 2, or 4 fail, do NOT provide vague prompts like *"It failed, try again."*
Format the error into an actionable, delimited diagnostic turn:

```markdown
<!-- Production Invariant: Actionable Diagnostic Repair Envelope -->
[Verification Failure: Gate 2 (Static Typecheck)]
Command: `pnpm tsc --noEmit`
Exit Code: 2

Errors:
1. `src/auth/jwt.ts:42:15` - error TS2345: Argument of type '{ algorithm: string }' is not assignable to parameter of type 'JwtVerifyOptions'.
   Object literal may only specify known properties, and 'algorithm' does not exist in type 'JwtVerifyOptions'. Did you mean 'algorithms'?

Action Required:
Inspect `src/auth/jwt.ts:42` and update the options parameter to match 'JwtVerifyOptions'.
```

---

## 8. Reference Implementation: Production-Grade Tolerant Patch Engine

Here is a battle-tested, zero-dependency TypeScript implementation of the multi-pass Search/Replace patch engine with atomic writes and safety guards:

```ts
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as crypto from 'node:crypto';

export interface PatchBlock {
  search: string;
  replace: string;
}

export interface PatchResult {
  success: boolean;
  filePath: string;
  matchedTier?: 'exact' | 'normalized_whitespace' | 'fuzzy_trimmed';
  error?: string;
}

export class SurgicalPatchEngine {
  /**
   * Applies an array of search/replace blocks sequentially to a target file.
   * Guarantees atomic writes and rolls back completely on any mismatch.
   */
  public static applyPatch(filePath: string, blocks: PatchBlock[]): PatchResult {
    const resolvedPath = path.resolve(filePath);
    if (!fs.existsSync(resolvedPath)) {
      return { success: false, filePath, error: `File not found: ${filePath}` };
    }

    const originalContent = fs.readFileSync(resolvedPath, 'utf-8');
    let currentContent = originalContent;
    let matchedTier: PatchResult['matchedTier'] = 'exact';

    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i];
      const match = this.findUniqueMatch(currentContent, block.search);

      if (!match.found) {
        return {
          success: false,
          filePath,
          error: `Block ${i + 1}/${blocks.length} failed to match: ${match.reason}`,
        };
      }

      matchedTier = match.tier;
      currentContent =
        currentContent.slice(0, match.startIndex) +
        block.replace +
        currentContent.slice(match.endIndex);
    }

    // Atomic write to disk via temporary file
    try {
      this.atomicWriteFile(resolvedPath, currentContent);
    } catch (err: unknown) {
      return {
        success: false,
        filePath,
        error: `Disk write failed: ${err instanceof Error ? err.message : String(err)}`,
      };
    }

    return { success: true, filePath, matchedTier };
  }

  private static findUniqueMatch(
    content: string,
    search: string
  ): { found: boolean; startIndex: number; endIndex: number; tier: PatchResult['matchedTier']; reason?: string } {
    // Pass 1: Exact Bit-for-bit string match
    const exactFirst = content.indexOf(search);
    if (exactFirst !== -1) {
      const exactSecond = content.indexOf(search, exactFirst + 1);
      if (exactSecond !== -1) {
        return {
          found: false,
          startIndex: -1,
          endIndex: -1,
          tier: 'exact',
          reason: 'Ambiguous match: SEARCH block matches multiple locations. Add more surrounding context.',
        };
      }
      return {
        found: true,
        startIndex: exactFirst,
        endIndex: exactFirst + search.length,
        tier: 'exact',
      };
    }

    // Pass 2: Normalized Whitespace & CRLF match
    const normContent = content.replace(/\r\n/g, '\n');
    const normSearch = search.replace(/\r\n/g, '\n');
    const normFirst = normContent.indexOf(normSearch);

    if (normFirst !== -1) {
      const normSecond = normContent.indexOf(normSearch, normFirst + 1);
      if (normSecond === -1) {
        // Map normalized indices back to original content
        return {
          found: true,
          startIndex: normFirst,
          endIndex: normFirst + normSearch.length,
          tier: 'normalized_whitespace',
        };
      }
    }

    // Pass 3: Trimmed-line comparison fallback
    const searchLines = normSearch.split('\n').map((l) => l.trim()).filter(Boolean);
    const contentLines = normContent.split('\n');

    let matchLineStart = -1;
    let matchCount = 0;

    for (let i = 0; i <= contentLines.length - searchLines.length; i++) {
      let allMatch = true;
      for (let j = 0; j < searchLines.length; j++) {
        if (contentLines[i + j].trim() !== searchLines[j]) {
          allMatch = false;
          break;
        }
      }
      if (allMatch) {
        matchCount++;
        matchLineStart = i;
      }
    }

    if (matchCount === 1) {
      // Calculate character index from matched lines
      const linesBefore = contentLines.slice(0, matchLineStart).join('\n');
      const matchedBlock = contentLines.slice(matchLineStart, matchLineStart + searchLines.length).join('\n');
      const startIdx = linesBefore.length > 0 ? linesBefore.length + 1 : 0;
      return {
        found: true,
        startIndex: startIdx,
        endIndex: startIdx + matchedBlock.length,
        tier: 'fuzzy_trimmed',
      };
    }

    if (matchCount > 1) {
      return {
        found: false,
        startIndex: -1,
        endIndex: -1,
        tier: 'fuzzy_trimmed',
        reason: `Ambiguous match: SEARCH block matched ${matchCount} separate locations.`,
      };
    }

    return {
      found: false,
      startIndex: -1,
      endIndex: -1,
      tier: 'exact',
      reason: 'SEARCH block not found in target file.',
    };
  }

  private static atomicWriteFile(targetPath: string, content: string): void {
    const dir = path.dirname(targetPath);
    const nonce = crypto.randomBytes(4).toString('hex');
    const tempPath = path.join(dir, `.${path.basename(targetPath)}.${process.pid}.${nonce}.tmp`);

    fs.writeFileSync(tempPath, content, { encoding: 'utf-8', mode: 0o644 });
    try {
      fs.renameSync(tempPath, targetPath);
    } catch (err) {
      if (fs.existsSync(tempPath)) {
        fs.unlinkSync(tempPath);
      }
      throw err;
    }
  }
}
```

---

## 9. Production Checklist: Agentic Code Intelligence & SWE Runtimes

Before running an AI coding agent or deploying an automated SWE harness, verify every invariant:

- [ ] **No Whole-File Dumps**: Does the agent default to discrete Search/Replace blocks rather than full-file rewrites for files $>50$ lines?
- [ ] **Uniqueness Guarantee**: Does the patch engine abort if a SEARCH block matches more than one location in the file?
- [ ] **Multi-Pass Normalization**: Does the patch engine gracefully handle `\r\n` vs `\n` line endings and trailing whitespace differences?
- [ ] **Pre-Commit AST Check**: Are patched contents validated for syntax validity via Tree-sitter or compiler dry-run before writing to disk?
- [ ] **Atomic File Writes**: Are file modifications written via temporary file rename to prevent half-written files on sudden process termination?
- [ ] **Blast Radius Analysis**: When public function signatures or exported types change, does the agent check all importing call sites?
- [ ] **Token-Budgeted Repo Map**: Is the repository map constrained to a fixed token ceiling (1k–4k tokens) using PageRank importance scoring rather than arbitrary directory trees?
- [ ] **Actionable Error Feedback**: Are compiler errors formatted with exact file paths, line numbers, and error codes for targeted self-correction?
- [ ] **Git Staging Isolation**: Are speculative modifications executed in isolated Git worktrees or branches with an instant rollback mechanism?
- [ ] **Workspace Boundary Containment**: Does every file path check resolve symlinks (`filepath.EvalSymlinks`) to prevent directory traversal outside the repository root?
