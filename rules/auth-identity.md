---
description: Authentication, Identity, OAuth 2.1, JWT security invariants, refresh token rotation, and session management
globs: **/*.{ts,js,py,go,rs,java,php,cs},**/auth/**,**/identity/**,**/oauth/**,**/session/**,**/jwt/**,**/tokens/**
alwaysApply: false
---

# Authentication, Identity & Token Production Invariants

> Add these rules to your project if implementing authentication flows, JWT issuance/verification, OAuth 2.1 / OIDC integrations, session management, or role-based access control (RBAC/ABAC).

## 1. Cryptographic JWT Invariants & Algorithm Discipline
- **Explicit Algorithm Whitelisting**:
  - ❌ **TOTAL BAN ON DYNAMIC OR CLIENT-SPECIFIED ALGORITHMS**:
    - Never accept the `alg` header from incoming tokens without verifying it against a hardcoded compile-time allowlist.
    - Absolute ban on `alg: "none"`.
  - **HMAC / RSA Key Confusion Defense**:
    - When verifying asymmetric JWTs (e.g., `RS256`, `ES256`, `EdDSA`), explicitly pass the expected algorithm to the verification library:
      ```ts
      // ❌ Catastrophic Key Confusion Vulnerability:
      // An attacker can forge a token signed with HMAC (HS256) using your public RSA key as the HMAC secret!
      jwt.verify(token, publicKey);

      // ✅ Strictly pin allowed algorithms:
      jwt.verify(token, publicKey, {
        algorithms: ['RS256'],
        issuer: 'https://auth.example.com',
        audience: 'https://api.example.com',
        clockTolerance: 60, // max 60s NTP clock drift
      });
      ```
- **Strict Claims Verification**:
  - Always validate `exp` (expiration), `nbf` (not before), `iat` (issued at), `iss` (issuer), and `aud` (audience).
  - Short-lived Access Tokens: Keep access token TTL brief (**5 to 15 minutes** maximum). Never issue 30-day or multi-week access tokens.
- **Minimal Claims Payload (No PII / Secrets)**:
  - ❌ **NEVER store passwords, API secrets, full permission trees, or sensitive PII in JWT payloads**. JWT payloads are base64url encoded and completely transparent to anyone who inspects the token.
  - Store only immutable identity pointers: `sub` (User ID), `org_id` (Tenant ID), and a `token_version` / `iat` counter for instant revocation.

## 2. Refresh Token Rotation (RTR) & Token Family Theft Detection
- **Single-Use Refresh Tokens**:
  - Refresh tokens MUST be strictly single-use. When a refresh token is presented to obtain a new access token, the auth server MUST immediately revoke that refresh token and issue a brand-new refresh token alongside the access token.
- **Token Family Tracking & Automatic Revocation on Reuse**:
  - Assign a unique `family_id` (UUID) to the initial login grant. Every rotated refresh token inherits the same `family_id`.
  - Track the state of every refresh token in the database (`consumed: boolean`).
  - 🚨 **AUTOMATIC BREACH CONTAINMENT**: If a refresh token that has ALREADY been marked as `consumed` is presented again, it indicates a replay attack or token theft (either the legitimate client or an attacker was intercepted):
    ```ts
    // Pseudocode for Refresh Token Rotation with Reuse Detection
    const storedToken = await db.refreshToken.findUnique({ where: { tokenHash } });
    if (!storedToken) {
      throw new UnauthorizedError('Invalid token');
    }

    if (storedToken.consumed) {
      // BREACH DETECTED: A consumed token was reused!
      // Invalidate the entire token family immediately to cut off the attacker.
      await db.refreshToken.deleteMany({ where: { familyId: storedToken.familyId } });
      await logSecurityIncident({
        userId: storedToken.userId,
        event: 'REFRESH_TOKEN_REUSE_DETECTED',
        familyId: storedToken.familyId,
      });
      throw new UnauthorizedError('Security violation detected. Please sign in again.');
    }

    // Mark current token as consumed
    await db.refreshToken.update({
      where: { id: storedToken.id },
      data: { consumed: true },
    });

    // Issue new pair with same familyId
    const newRefreshToken = generateSecureToken();
    await db.refreshToken.create({
      data: {
        tokenHash: hashSha256(newRefreshToken),
        familyId: storedToken.familyId,
        userId: storedToken.userId,
        expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
      },
    });
    ```
- **Hash Refresh Tokens at Rest**:
  - ❌ **NEVER store refresh tokens in plaintext in the database**. Store their SHA-256 cryptographic hashes (`hashSha256(token)`). If the database is dumped, the leaked hashes cannot be used to exchange for access tokens.

## 3. Storage Security & Cookie Hardening
- ❌ **TOTAL BAN ON `localStorage` / `sessionStorage` FOR AUTH TOKENS**:
  - LLMs constantly generate `localStorage.setItem('accessToken', token)`. Any Cross-Site Scripting (XSS) vulnerability or compromised third-party npm package can instantly exfiltrate the token.
- **Hardened Cookie Invariants**:
  - Store session tokens and refresh tokens in `HttpOnly`, `Secure`, and `SameSite` cookies:
    - `HttpOnly`: Prevents client-side JavaScript (`document.cookie`) from reading or exfiltrating the token.
    - `Secure`: Guarantees cookies are transmitted exclusively over encrypted HTTPS connections.
    - `SameSite=Lax` or `SameSite=Strict`: Shields against Cross-Site Request Forgery (CSRF). For state-mutating endpoints (`POST`, `PUT`, `DELETE`), pair with `SameSite=Lax` plus custom header verification (`Origin` / `Sec-Fetch-Site` checks).
  - **Use `__Host-` Cookie Prefixes**:
    - The `__Host-` prefix enforces that the cookie is secure, sent only to the host domain (no subdomains), and has `Path=/`:
      ```http
      Set-Cookie: __Host-session=xyz123; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=1209600
      ```

## 4. OAuth 2.1 & OpenID Connect (OIDC) Discipline
- **Mandatory PKCE (Proof Key for Code Exchange)**:
  - PKCE (`code_challenge` / `code_verifier`) with `code_challenge_method: S256` is MANDATORY for all OAuth clients (Single-Page Apps, mobile apps, and confidential server-side backends).
  - ❌ **Ban `code_challenge_method: plain`**: Always use SHA-256 (`S256`).
- **CSRF Defense via `state` and Nonce Verification**:
  - Always generate a cryptographically random `state` parameter bound to the user's session before redirecting to the authorization server.
  - Verify that the returned `state` query parameter exactly matches the session `state` in constant time before exchanging the authorization code.
  - In OIDC flows, generate a random `nonce` in the authentication request and verify that the resulting ID token's `nonce` claim matches.
- **Exact Redirect URI Matching**:
  - ❌ **NEVER use wildcards (`*`), regexes, or partial domain matching on `redirect_uri`**:
    - Attackers bypass loose checks with subdomains or open redirects (`https://example.com.attacker.com`).
  - The authorization server MUST perform exact, case-sensitive string matching against pre-registered callback URLs.
- **Deprecation of Dangerous Legacy Grants**:
  - ❌ Strictly ban the **Implicit Flow** (`response_type=token`, which returns tokens directly in the URL hash fragment).
  - ❌ Strictly ban the **Resource Owner Password Credentials (ROPC)** grant (which teaches users to enter credentials into untrusted client apps).

## 5. Authorization, Tenant Isolation & BOLA/IDOR Elimination
- **Broken Object Level Authorization (BOLA / IDOR) Defense**:
  - Authentication confirms *who* a user is; authorization confirms *what* they are allowed to mutate or read.
  - ❌ **NEVER trust client-supplied resource IDs without verifying ownership or tenancy**:
    ```ts
    // ❌ Catastrophic IDOR: Attacker can modify any user's profile by changing the URL param
    app.patch('/api/profiles/:id', async (req, res) => {
      await db.profile.update({
        where: { id: req.params.id },
        data: req.body,
      });
    });

    // ✅ Enforce tenant/user scoping on every single query:
    app.patch('/api/profiles/:id', async (req, res) => {
      const updated = await db.profile.updateMany({
        where: {
          id: req.params.id,
          userId: req.user.id,       // Scoped to authenticated user
          tenantId: req.user.tenantId // Multi-tenant isolation guard
        },
        data: sanitize(req.body),
      });
      if (updated.count === 0) {
        throw new NotFoundError('Profile not found or access denied');
      }
    });
    ```
- **Step-Up Authentication for High-Risk Actions**:
  - Sensitive operations (changing passwords/emails, disabling MFA, generating API tokens, changing payment destinations, deleting accounts) MUST require step-up re-authentication:
    - Check if the session was authenticated within the last 5 minutes (`auth_time`).
    - If older than 5 minutes, require an immediate password confirmation or WebAuthn/TOTP challenge before proceeding.

## 6. WebAuthn, Passkeys & Session Fixation Immunity
- **WebAuthn Verification Discipline**:
  - **Challenge Validation**: Authentication challenges must be CSPRNG-generated (`crypto.randomBytes(32)`), stored in the server session with an expiry `<= 2 minutes`, and invalidated immediately after first verification.
  - **Relying Party (RP) ID Verification**: Verify that the client data JSON's `origin` and `rpId` match the expected server domain.
  - **Signature Counter Monotonicity**:
    - Authenticators maintain a monotonically increasing counter (`counter`).
    - During assertion verification, verify that `newCounter > storedCounter`. If `newCounter <= storedCounter` (and non-zero), an authenticator clone has been detected—abort immediately.
- **Session Fixation Defense**:
  - When a user logs in, escalates privileges, or switches accounts, **always destroy the existing session ID and issue a completely new session ID**.
  - Never retain a pre-authentication session cookie or ID after successful authentication.
- **Constant-Time Verification**:
  - Compare passwords hashes with specialized libraries (`bcrypt.compare`, `argon2.verify`).
  - Always verify raw tokens, webhook secrets, or API keys using constant-time comparison (`crypto.timingSafeEqual`) to prevent byte-by-byte timing attacks.
