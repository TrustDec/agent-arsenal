---
description: Agentic Code-as-Action (CodeAct), stateful REPL execution, programmatic tool orchestration, intermediate data filtering at source, context window shielding, Python/Node/Bash REPL sandbox lifecycles, and output truncation guardrails across Claude Code, Cursor, Windsurf, Roo Code, Pi, and OpenCode
globs: **/*{codeact,repl,executor,runner,sandbox,action,eval,interpreter,kernel}*.*,**/repl/**,**/runners/**,**/executors/**,**/sandbox/**
alwaysApply: false
---

# Agentic Code-as-Action (CodeAct), REPL-Driven Tool Orchestration & Programmatic Context Compaction

> Add these rules to your project when architecting, executing, or optimizing autonomous coding agents, interactive terminal runners, or tool-calling harnesses (Claude Code, Cursor Composer, Windsurf Cascade, Roo Code, Pi, OpenCode, SWE-agent, smolagents). Terminate the JSON tool-calling context tax and replace fragile multi-turn function chaining with Turing-complete, stateful programmatic execution.

---

## 1. Architectural Taxonomy: The JSON Tool-Calling Trap vs Code-as-Action (CodeAct)

In autonomous agent systems, the dominant cause of context window exhaustion, latency degradation, and reasoning hallucination is the **JSON Tool-Calling Bottleneck**:

- **The JSON Tool-Calling Trap ($O(N)$ Conversation Bloat & Attention Dissipation)**:
  - When agents interact with environments purely via JSON schemas, every trivial operation requires an LLM inference round-trip.
  - *Example*: Finding 5 customer records with delinquent payments from a collection of 5,000 files.
    - Traditional JSON Agent: Invokes `list_files` $\to$ receives 5,000 JSON entries (40,000 tokens) $\to$ model context saturates $\to$ calls `read_file` sequentially 50 times $\to$ burns 250,000 tokens, costs $3.50, takes 90 seconds, and frequently hallucinates midway due to attention degradation.
  - JSON schemas cannot express control flow, loops, branch logic, or temporary variables without bouncing back to the model after every single action.
- **The Code-as-Action (CodeAct) Invariant (Turing-Complete Local Computation)**:
  - Instead of emitting fragmented JSON tool parameters, the agent synthesizes executable code (Python, TypeScript, or Bash) executed within a persistent, stateful REPL environment.
  - The agent queries databases, reads files, calls external REST/GraphQL APIs, transforms dataframes, and applies conditional logic *locally inside the runtime*.
  - **The Filter-at-Source Law**: Megabytes of raw telemetry, file listings, or database records are aggregated, filtered, and compacted *inside the REPL*. Only the synthesized, high-density summary (e.g. 5 JSON lines or a concise Markdown table) is emitted to `stdout` for LLM consumption.
  - Reduces token consumption by $90\text{--}98\%$, executes loops with zero LLM latency overhead, and turns the agent into a genuine programmatic orchestrator.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Feature Goal / User Query: "Aggregate error spikes from 200 service log files"                  │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
         ┌────────────────────────────────────────┴────────────────────────────────────────┐
         │                                                                                 │
         ▼ [ANTI-PATTERN: Fragile JSON Tool Calling]                                       ▼ [PRODUCTION: CodeAct Stateful REPL]
┌─────────────────────────────────────────────────┐               ┌─────────────────────────────────────────────────┐
│ Turn 1: LLM generates {"tool": "list_files"}   │               │ Turn 1: LLM generates complete Python script    │
│ Host returns 200 file paths (5,000 tokens)      │               │ that searches, filters, and computes in memory  │
├─────────────────────────────────────────────────┤               ├─────────────────────────────────────────────────┤
│ Turn 2: LLM loops: {"tool": "read_file", ...}   │               │ ```python                                       │
│ Host returns 500 lines of log (8,000 tokens)    │               │ import glob, re, json, collections              │
├─────────────────────────────────────────────────┤               │ counter = collections.Counter()                 │
│ Turn 3..20: Repeats 20 times...                 │               │ for path in glob.glob('/var/log/svc-*.log'):    │
│ Context window explodes past 150k tokens        │               │   with open(path) as f:                         │
│ Model loses needle-in-haystack attention        │               │     for line in f:                              │
│ Total Tokens: ~180,000 | Latency: 120s          │               │       if 'ERROR' in line:                       │
│ Cost: $2.80 | High Hallucination Risk           │               │         counter[extract_signature(line)] += 1   │
└─────────────────────────────────────────────────┘               │ print(json.dumps(counter.most_common(5)))       │
                                                                  │ ```                                             │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Execution in Isolated REPL Sandbox              │
                                                                  │ Filesystem I/O & Filtering executed locally     │
                                                                  ├─────────────────────────────────────────────────┤
                                                                  │ Host emits ONLY concise filtered stdout:        │
                                                                  │ [{"sig": "ECONNREFUSED:5432", "count": 1420},   │
                                                                  │  {"sig": "JWT_EXPIRED", "count": 89}]           │
                                                                  │ Total Tokens: 250 | Latency: 3.2s               │
                                                                  │ Cost: $0.004 | Zero Attention Loss              │
                                                                  └─────────────────────────────────────────────────┘
```

---

## 2. Stateful REPL Architecture & Session Namespace Persistence

### 2.1 The Stateful Multi-Turn Invariant
In autonomous workflows, launching an isolated process per tool turn destroys variables, imports, and connections, forcing expensive reconnections and redundant data re-fetching. Autonomous harnesses must maintain a persistent REPL kernel (e.g. IPython kernel, persistent Node.js context, or background bash subshell with FIFO/pty):

- ❌ **Anti-Pattern: Ephemeral Shell Command Disconnect**:
  Running `bash -c "DB_URL=... python fetch.py"` followed in the next turn by `bash -c "python analyze.py"` where `analyze.py` has no access to the fetched in-memory dataframe, forcing disk serialization or repeated queries.
- ✅ **Production Invariant: Persistent Session Namespace**:
  All execution turns within a sub-task share a single long-lived REPL session. Variables, imported modules, database connection pools, and synthesized helper functions remain in scope across conversational turns:

```python
# Session Cell 1: Initialize pool and authenticate once
import os, psycopg2, pandas as pd
from psycopg2.pool import ThreadedConnectionPool

pg_pool = ThreadedConnectionPool(
    minconn=1, maxconn=5,
    dsn=os.environ["DATABASE_URL"]
)
print("Pool initialized.")

# Session Cell 2 (Subsequent Turn): Reuse pg_pool directly without re-authenticating
conn = pg_pool.getconn()
try:
    df = pd.read_sql("SELECT status, count(*) FROM orders GROUP BY status;", conn)
finally:
    pg_pool.putconn(conn)

print(df.to_string(index=False))
```

### 2.2 Namespace Hygiene & Memory Leak Avoidance
- **Scratchpad Deletion**: Autonomous agents operating in long-lived REPLs must explicitly clean up large temporary allocations (`del big_df; gc.collect()`) before initiating subsequent sub-tasks.
- **Session Introspection**: When an agent suffers context compaction or recovers from a disconnect, it must query the active namespace rather than re-running the entire initialization pipeline:
  - In Python: execute `[k for k in dir() if not k.startswith('_')]` or `%who_ls`
  - In Bash: execute `compgen -v` or inspect exported functions with `declare -F`

---

## 3. The "Filter-at-Source" Invariant & Context Window Shielding

### 3.1 The Cardinal Rule of Data Density
Raw payload streams must NEVER enter the LLM's conversation context uncompacted. If an operation produces more than **50 lines** or **10 KB** of raw text, the agent must perform programmatic aggregation, projection, or pagination *within the script*.

```
Raw Source Data (API / DB / Logs / DOM)
               │ (10MB - 1GB)
               ▼
┌──────────────────────────────────────────────┐
│ REPL Sandbox Memory / Scratchpad Buffer     │
│ • Filter: grep / jq / regex / SQL WHERE     │
│ • Aggregate: groupby / sum / top-k          │
│ • Project: pluck relevant attributes only    │
└──────────────────────┬───────────────────────┘
                       │ High-Density Digest (<= 50 lines / <= 2KB)
                       ▼
       LLM Conversation Context Window
```

### 3.2 Output Truncation & Dual-Buffer Offloading Protocol
Harnesses must enforce strict stdout/stderr execution ceilings. If a synthesized script mistakenly dumps an unbounded stream:

1. **The 2000-Line / 50KB Hard Ceiling**: Truncate output at `min(2000 lines, 50 KB)`.
2. **Head + Tail Preservation**: Do not truncate blindly from the end; retain the first 50 lines (headers, initialization) and the last 150 lines (final results, summary metrics, or fatal error tracebacks).
3. **Scratchpad File Spillover**: Dump the full, raw output to an ephemeral scratchpad file (`/tmp/agent_scratchpad_<session_id>_<turn>.log`) and emit a standardized XML pointer into stdout:

```xml
<tool_output_truncated bytes="482910" total_lines="14200" displayed_lines="200">
[First 50 lines displayed...]
... [14,000 lines omitted to preserve LLM context budget] ...
[Last 150 lines displayed...]
<scratchpad_spillover path="/tmp/agent_scratchpad_sess99_turn4.log" />
<recovery_hint>Use programmatic filtering (e.g. grep, jq, head, tail, or Python slice) to inspect specific offsets of the spillover file rather than catting the entire payload.</recovery_hint>
</tool_output_truncated>
```

---

## 4. Programmatic Tool Composition & Local Concurrency

### 4.1 Fan-Out / Fan-In Without Round-Trip Latency
When an agent must interrogate 50 endpoints, scan 100 Git commits, or validate 80 microservices, issuing 80 sequential LLM turns takes minutes and incurs prohibitive token costs. The agent must synthesize concurrent batch pipelines directly in the execution cell:

```python
# Production CodeAct: Concurrent interrogation with local error aggregation
import asyncio, httpx

TARGET_ENDPOINTS = [
    f"http://internal.service.mesh/health/{svc}"
    for svc in ["auth", "billing", "users", "inventory", "search", "gateway"]
]

async def check_all():
    async with httpx.AsyncClient(timeout=3.0) as client:
        tasks = [client.get(url) for url in TARGET_ENDPOINTS]
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
    failures = []
    for url, res in zip(TARGET_ENDPOINTS, results):
        if isinstance(res, Exception):
            failures.append({"url": url, "error": str(res)})
        elif res.status_code != 200:
            failures.append({"url": url, "status": res.status_code, "body": res.text[:100]})
            
    # Emit ONLY anomalies to LLM context
    if not failures:
        print("ALL_SYSTEMS_HEALTHY (6/6 passed)")
    else:
        print(f"ANOMALIES_DETECTED ({len(failures)} failed):")
        for f in failures:
            print(f" - {f}")

asyncio.run(check_all())
```

### 4.2 In-Code Retries with Exponential Backoff
Never bounce back to the LLM to ask "Should I retry?" when encountering transient network glitches or rate limits. Retries belong inside the execution code:

```python
import time, random

def resilient_exec(fn, max_retries=3, base_delay=0.5):
    for attempt in range(max_retries):
        try:
            return fn()
        except (TimeoutError, ConnectionResetError) as err:
            if attempt == max_retries - 1:
                raise
            sleep_duration = base_delay * (2 ** attempt) + random.uniform(0, 0.2)
            time.sleep(sleep_duration)
```

---

## 5. Non-Interactive Execution, Timeouts & Deterministic Traceback Triage

### 5.1 The Absolute Non-Interactive Execution Guarantee
Autonomous agents freeze when sub-processes wait on `stdin` for user confirmation (e.g. `apt-get`, `git pull`, `npm init`, `python -m input()`). Every REPL and subshell execution must enforce non-interactive environments:

```bash
# Non-interactive shell environment invariants
export DEBIAN_FRONTEND=noninteractive
export CI=true
export GIT_TERMINAL_PROMPT=0
export PIP_NO_INPUT=1
export NPM_CONFIG_YES=true
```

In Python scripts, monkey-patch or disable `builtins.input`:
```python
import builtins
def _disabled_input(prompt=""):
    raise RuntimeError(f"Interactive input() is prohibited in autonomous CodeAct execution. Prompt was: {prompt}")
builtins.input = _disabled_input
```

### 5.2 Deterministic Subprocess & Cell Timeout Guardrails
Every REPL cell execution must be bound to a strict timeout watchdog. When a script enters an infinite loop (`while True:`):
1. **The 30-Second Alarm**: Enforce cell timeout via `signal.SIGALRM` or process-level cancellation tokens.
2. **Process Group Teardown**: Upon timeout, kill the entire process tree using negative PID (`os.killpg(os.getpgid(p.pid), signal.SIGTERM)`), followed by `SIGKILL` after 2 seconds if stubborn child threads remain alive.

### 5.3 Traceback Triage & Surgical Error Extraction
When code throws an exception, standard library frames (100+ lines of Python internal imports or Node.js internal modules) clutter context. The harness must extract and format a **Surgical Traceback Digest**:

```
❌ Execution Failed: ZeroDivisionError
File "/workspace/src/aggregator.py", line 42, in calculate_average
   -> return total / count
ZeroDivisionError: division by zero

[REPL Context Hint: 'count' evaluated to 0. Inspect 'count' derivation before re-running.]
```

---

## 6. The 5-Step CodeAct Self-Correction FSM

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 1: Synthesize Minimal Code Hypothesis                                                      │
│    • Express tool orchestration, loops, filtering, and assertion checks in single executable cell │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                                                  ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 2: Execute in Stateful REPL Sandbox                                                         │
│    • Enforce non-interactive flags, timeouts, and stdout buffer ceilings                          │
└─────────────────────────────────────────────────┬────────────────────────────────────────────────┘
                                                  │
                         ┌────────────────────────┴────────────────────────┐
                         │                                                 │
                         ▼ Execution Success (Exit 0)                      ▼ Execution Failure / Exception
┌─────────────────────────────────────────────────┐       ┌─────────────────────────────────────────────────┐
│ Step 3: Validate Invariant Assertion            │       │ Step 4: Traceback Localization                  │
│    • Verify stdout output matches domain schema │       │    • Extract failing line & exception type      │
│    • Check for empty / degenerate results       │       │    • Interrogate local variable state via REPL  │
└────────────────────────┬────────────────────────┘       │    • Synthesize targeted patch (max 3 attempts) │
                         │ Assertions Pass                └────────────────────────┬────────────────────────┘
                         ▼                                                         │ Retry with Patch
┌─────────────────────────────────────────────────┐                                │
│ Step 5: Commit Result & Clean Scratchpad        │◀───────────────────────────────┘
│    • Release large in-memory buffers            │
│    • Format dense markdown answer for user      │
└─────────────────────────────────────────────────┘
```

---

## 7. Machine-Verifiable Definition of Done (DoD) Matrix

An autonomous agent operating via CodeAct must not declare a task complete until all 6 verification gates pass:

| Gate | Check | Verification Method | Failure Action |
|---|---|---|---|
| **1. Zero Context Spilling** | Output $\le 50$ lines and $\le 10$ KB | Byte count assertion on stdout | Wrap in programmatic aggregator/filter |
| **2. Clean Exit Code** | Execution returns exit code `0` | Subprocess returncode / REPL status | Triage traceback and apply targeted fix |
| **3. Non-Interactive Guarantee** | No blocking `stdin` / interactive prompts | Test with `/dev/null` piped to stdin | Inject non-interactive environment flags |
| **4. Process Tree Hygiene** | Zero orphaned or zombie background processes | `pgrep -P <pid>` verification | Issue `kill -9` to lingering process group |
| **5. Ephemeral Resource Teardown**| Scratchpad files and large variables evicted | `os.path.exists()` and `del df; gc.collect()` | Purge temporary files from `/tmp` |
| **6. Deterministic Output** | Output contains concrete verified domain data | Regexp / JSON parse assertion | Abort on mock/tautological empty strings |

---

## 8. Absolute Prohibitions (Anti-Patterns)

- 🚫 **Total Ban on Unfiltered Raw Cat / Select**: Never run `cat mega_file.json` or `SELECT * FROM large_table` directly into stdout without `grep`, `jq`, `LIMIT`, or programmatic aggregation.
- 🚫 **Total Ban on Multi-Turn Interactive Confirmation Prompts**: Never execute commands that prompt `Are you sure? (y/N)`. Always pass `--yes`, `-y`, `--force`, or set non-interactive flags.
- 🚫 **Total Ban on Discarding Non-Zero Exit Codes**: Never append `; true` or `|| exit 0` to mask a failing script or test in an autonomous loop.
- 🚫 **Total Ban on Ephemeral Re-Authentication**: Never re-authenticate or re-initialize expensive database pools or client connections on every single turn when a persistent session is available.
- 🚫 **Total Ban on Infinite Polling Without Backoff**: Never run tight `while True: pass` loops inside the REPL; always inject timeouts, backoff sleeps, and hard iteration ceilings ($N \le 100$).
