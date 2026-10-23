---
description: Python & FastAPI production invariants, strict typing, async event loop hygiene, and Pydantic V2 discipline
globs: **/*.py,**/pyproject.toml,**/requirements*.txt
alwaysApply: false
---

# Python & FastAPI Production Invariants

> Add these rules to your project if developing in Python, FastAPI, Django, or modern async backends.

## 1. Type Hints & Pydantic V2 Invariants
- **Mandatory Strict Type Annotations**:
  - All function signatures (arguments, defaults, and return values) MUST have complete type annotations compatible with `mypy --strict`.
  - Never use untyped `dict` or `Any` for API payloads or database models.
- **Pydantic V2 Modern Discipline**:
  - ❌ **BAN DEPRECATED V1 METHODS**: Never use `.dict()`, `.parse_obj()`, or `class Config:`.
  - Always use Pydantic V2 APIs:
    - Serialization: `model.model_dump()` or `model.model_dump_json()`
    - Deserialization & validation: `Model.model_validate(raw_data)` or `Model.model_validate_json(raw_json)`
    - Configuration: `model_config = ConfigDict(extra="forbid", frozen=True)`
- **Mutable Default Arguments Trap**:
  - ❌ NEVER use mutable defaults: `def process(items: list[str] = []):` or `def setup(opts: dict = {}):`.
  - Always use `None` as default with factory initialization: `def process(items: list[str] | None = None): items = items if items is not None else []`.

## 2. Async Event Loop Hygiene (Zero Blocking Calls in `async def`)
- ❌ **NEVER BLOCK THE ASYNC EVENT LOOP**:
  - Calling synchronous blocking I/O inside an `async def` route halts the entire single-threaded Python event loop, starving all other concurrent requests.
  - **Forbidden inside `async def`**:
    - `time.sleep()` ➔ Use `asyncio.sleep()`.
    - `requests.get()` ➔ Use `httpx.AsyncClient()`.
    - Blocking disk I/O (`open().read()`) ➔ Use `aiofiles` or `anyio.to_thread.run_sync()`.
    - Synchronous ORM calls or CPU-bound tasks ➔ Offload with `await anyio.to_thread.run_sync(blocking_fn, arg1)`.
  - **FastAPI Thread Pool Rule**:
    - If a third-party library is purely synchronous and cannot be converted to async, declare the FastAPI route handler as a standard `def` (without `async`). FastAPI will automatically schedule standard `def` endpoints on an external worker thread pool.

## 3. Explicit Error Handling & Zero Silent Swallowing
- ❌ **TOTAL BAN ON `except Exception: pass` AND NAKED `except:`**:
  - Never swallow exceptions silently.
  - Catch narrow, specific exceptions (`ValueError`, `KeyError`, `httpx.HTTPStatusError`).
  - When logging exceptions, ALWAYS use `logger.exception("Failed to process transaction %s", tx_id)` to retain the full stack trace for root-cause diagnosis.
- **Explicit Custom Exception Hierarchies**:
  - Define domain exceptions derived from a base application error. Convert them to structured HTTP responses using FastAPI `@app.exception_handler()`.

## 4. Application Lifespan & Resource Management
- ❌ **DEPRECATE `@app.on_event("startup")` / `"shutdown"`**:
  - Always use the modern FastAPI `lifespan` context manager to guarantee deterministic initialization and teardown of database connection pools, Redis clients, and HTTP sessions:
    ```python
    from contextlib import asynccontextmanager
    from fastapi import FastAPI
    import httpx

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Startup: initialize shared pooled resources
        app.state.http_client = httpx.AsyncClient(timeout=10.0)
        yield
        # Teardown: cleanly close all pooled resources
        await app.state.http_client.aclose()

    app = FastAPI(lifespan=lifespan)
    ```

## 5. SQL Safety & Parameterized Queries
- ❌ **NEVER USE F-STRINGS OR FORMATTING FOR SQL**:
  - Raw string interpolation (`f"SELECT * FROM users WHERE email = '{email}'"`) is a severe security vulnerability.
  - Always use SQLAlchemy/SQLModel parameterized queries: `select(User).where(User.email == email)`.

## 6. Verification Protocol
- Before declaring task completion, verify:
  1. Linter & Formatter: `ruff check .` and `ruff format --check .`
  2. Type Checker: `mypy .`
  3. Tests: `pytest`
