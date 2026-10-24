---
description: Application security (AppSec), OWASP Top 10 defense, SSRF/injection prevention, secrets hygiene, and cryptographic invariants
globs: **/*.{ts,js,py,go,rs,java,rb,php,cs,sql,sh}
alwaysApply: false
---

# Application Security (AppSec) & Defensive Engineering Invariants

> Add these rules to your project if writing web APIs, authentication flows, file uploaders, network clients, or microservices. Prevent LLM-generated security vulnerabilities before they reach production.

## 1. Server-Side Request Forgery (SSRF) Defense
- ❌ **TOTAL BAN ON UNVALIDATED REMOTE FETCHING**:
  - LLMs love generating naive `fetch(userUrl)` or `requests.get(userUrl)` for webhooks, proxy endpoints, or avatar downloaders.
  - This allows attackers to access cloud metadata instances (`http://169.254.169.254/latest/meta-data/`), internal microservices, and Docker/Kubernetes daemon ports.
- **Mandatory SSRF Invariants**:
  1. **Strict Protocol Whitelist**: Permit ONLY `http:` and `https:`. Reject `file:`, `gopher:`, `ftp:`, `data:`, `ldap:`.
  2. **Pre-Flight DNS Resolution & IP Range Validation**: Resolve the hostname before connecting and reject private/reserved CIDR blocks:
     - IPv4 Loopback: `127.0.0.0/8`
     - IPv4 RFC 1918 Private: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
     - IPv4 Link-Local / Cloud Metadata: `169.254.0.0/16`
     - IPv4 Broadcast / Reserved: `0.0.0.0/8`, `224.0.0.0/4`, `240.0.0.0/4`
     - IPv6 Loopback / Private: `::1`, `fc00::/7`, `fe80::/10`
  3. **Disable Automatic Redirect Following**: Attackers use open redirects on external domains to pivot to internal IP addresses. Inspect every redirect destination against the IP validator.

## 2. Injection Immunity (Command, SQL, Dynamic Code)
- ❌ **BAN STRING CONCATENATION IN SQL & COMMANDS**:
  - Never execute SQL queries with concatenated or interpolated variables (`SELECT * FROM users WHERE id = '${id}'`). Always use parameterized queries / prepared statements (`$1`, `?`).
  - Table and column names CANNOT be parameterized. If dynamic columns are required, validate them against an explicit, immutable allowlist enum:
    ```ts
    const ALLOWED_SORT_COLUMNS = ['created_at', 'updated_at', 'price'] as const;
    if (!ALLOWED_SORT_COLUMNS.includes(inputCol)) {
      throw new BadRequestError('Invalid sort column');
    }
    ```
- ❌ **BAN SHELL INTERPOLATION & DYNAMIC EVAL**:
  - In Node.js: Never use `child_process.exec()` with concatenated strings. Use `child_process.execFile()` or `spawn()` with discrete argument arrays and `shell: false`.
  - In Python: Never use `os.system()` or `subprocess.Popen(..., shell=True)`. Pass list arguments `['git', 'status']`.
  - Absolute ban on `eval()`, `new Function()`, `vm.runInThisContext()`, Python `exec()` / `eval()`.

## 3. Path Traversal & File Upload Hardening
- **Path Traversal Invariants**:
  - Never trust user-supplied file names or relative paths.
  - Always resolve paths against an explicit base directory and verify that the canonical resolved path remains within that boundary:
    ```ts
    const safePath = path.resolve(STORAGE_ROOT, path.normalize(userInputPath));
    if (!safePath.startsWith(STORAGE_ROOT + path.sep)) {
      throw new ForbiddenError('Path traversal attempt detected');
    }
    ```
  - Strip null bytes (`\0`) and reject names containing `..` or leading slashes.
- **File Upload Discipline**:
  - Never save files using the client's `originalname` directly to disk. Generate an immutable UUID v4 (`${crypto.randomUUID()}.${ext}`).
  - Validate file types by reading magic bytes (file signature), NEVER by trusting the client-supplied `Content-Type` header or file extension alone.
  - Store uploads outside the web server root or in object storage (S3/GCS) with private access policies.

## 4. Cryptographic Safety & Timing Attacks
- **Constant-Time Verification**:
  - ❌ Never use `===` or `==` or `!=` to verify HMAC signatures, API tokens, passwords, or webhook verification secrets. Standard string equality leaks execution time byte-by-byte (timing attack).
  - Use constant-time comparison functions:
    - Node.js: `crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expectedSig))`
    - Python: `hmac.compare_digest(sig, expected_sig)`
    - Go: `subtle.ConstantTimeCompare([]byte(a), []byte(b))`
- **Cryptographic PRNG Only**:
  - ❌ Never use `Math.random()` or Python `random.random()` for security tokens, reset codes, CSRF tokens, or salt generation.
  - Use CSPRNG: `crypto.randomBytes()`, `crypto.randomUUID()`, or Python `secrets.token_urlsafe()`.
- **Password Hashing**:
  - Never use fast hashes (MD5, SHA-1, SHA-256) for passwords.
  - Use memory-hard key derivation algorithms: Argon2id (preferred) or bcrypt with an adaptive cost factor (`>= 12`).

## 5. Secrets Hygiene & Data Leakage Prevention
- **Zero Secrets in Code or VCS**:
  - Never hardcode API keys, database credentials, JWT private keys, or passwords in source files, mock files, or unit tests.
  - Enforce environment variable extraction with runtime type validation (e.g., Zod, Envalid, Pydantic BaseSettings). Fail fast at application boot if required secrets are missing.
- **Log Sanitation**:
  - Mask or redact sensitive fields before logging: `Authorization`, `Cookie`, `Set-Cookie`, `password`, `token`, `credit_card`.
  - ❌ Never log full HTTP request bodies (`console.log(req.body)`) on authentication or payment endpoints.
- **Safe Error Responses**:
  - Never return raw database errors, stack traces, or internal server paths in HTTP 500 error responses to clients.
  - Return opaque incident IDs (`{ "error": "Internal Server Error", "error_id": "err_01H... }`) and log the detailed stack trace internally.

## 6. Regular Expression Denial of Service (ReDoS) Defense
- **Catastrophic Backtracking Prevention**:
  - Avoid nested quantifiers on overlapping character sets: `(a+)+`, `([a-zA-Z0-9]+)*`, `(a|aa)+$`.
  - Bound the maximum input length before applying regular expressions:
    ```ts
    if (userInput.length > 500) {
      throw new BadRequestError('Input exceeds maximum allowable length');
    }
    ```
- Use deterministic linear-time regex engines (e.g. Go `regexp`, Rust `regex`, or Google RE2) when matching against untrusted user inputs.
