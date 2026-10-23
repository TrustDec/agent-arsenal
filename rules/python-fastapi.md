# Python & FastAPI Production Invariants

> Add these rules to your project if developing in Python, FastAPI, or Django.

## 1. Type Hints Are Mandatory
- All function signatures (arguments and return types) MUST have full type annotations (`mypy` compliant).
- Use `Pydantic` models for request/response payloads in FastAPI; never return raw, untyped dictionaries.

## 2. No Silent Excepts
- ❌ **NEVER USE `except:` or `except Exception: pass`**.
- Always catch specific exception classes (`ValueError`, `HTTPError`) and log the stack trace using `logging.exception()`.

## 3. Dependency & Environment Safety
- Never run `pip install` globally. Always verify the virtual environment (`.venv`).
- Check `pyproject.toml` or `requirements.txt` to confirm library versions before calling APIs.
