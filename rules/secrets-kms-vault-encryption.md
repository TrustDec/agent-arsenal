---
description: Secrets management, KMS envelope encryption, AWS KMS, HashiCorp Vault, AES-256-GCM nonce reuse catastrophe, memory zeroization, dynamic ephemeral credentials, secret rotation, blind indexing for searchable PII, and zero-trust cryptographic invariants
globs: **/*{secret,kms,vault,crypto,encrypt,decrypt,key,cipher,envelope,token,credential}*.*,**/crypto/**,**/secrets/**,**/security/**,**/kms/**
alwaysApply: false
---

# Secrets Management, KMS Envelope Encryption & Zero-Trust Cryptographic Invariants

> Add these rules to your project when designing, implementing, or auditing cryptographic services, secrets management, key rotation engines, envelope encryption pipelines, or compliance-bound zero-trust infrastructures (PCI-DSS, HIPAA, SOC 2 Type II, GDPR) using AWS KMS, HashiCorp Vault, GCP Cloud KMS, or native cryptographic primitives.

---

## 1. Architectural Taxonomy: Secrets Hierarchy & Envelope Encryption
Directly encrypting high-volume application data with a centralized cloud KMS API creates severe operational bottlenecks, network latency, multi-thousand-dollar API bills, and hard rate-limiting throttles (e.g., AWS KMS 10,000–55,000 req/s ceiling per account). 

```
                                  ┌─────────────────────────────┐
                                  │      Cloud KMS / HSM        │
                                  │  (Master Key / KEK never   │
                                  │   leaves the secure enclave)│
                                  └──────────────┬──────────────┘
                                                 │
                                 1. GenerateDataKey(KEK_ID)
                                                 │
                                                 ▼
               ┌─────────────────────────────────────────────────────────────────┐
               │                        Application Node                         │
               │                                                                 │
               │   Plaintext DEK (256-bit)  ◄─── Encrypted DEK (CiphertextBlob)  │
               │             │                                 │                 │
               │             ▼                                 │                 │
               │    Local AES-256-GCM / ChaCha20               │                 │
               │             │                                 │                 │
               │             ▼                                 ▼                 │
               │   Payload Ciphertext           Stored Encrypted DEK             │
               │             │                                 │                 │
               │             └────────────────┬────────────────┘                 │
               │                              ▼                                  │
               │                 Database / Storage Record                       │
               │       [Encrypted_DEK | Nonce | Ciphertext | Auth_Tag]           │
               │                              │                                  │
               │       * Plaintext DEK wiped immediately via Zeroize! *          │
               └─────────────────────────────────────────────────────────────────┘
```

- ❌ **THE DIRECT KMS API CALL ANTIPATTERN**:
  - Sending raw records, files, or tokens across the WAN to `kms:Encrypt` for every database row or file chunk. This leaks database record structures to cloud access logs, consumes round-trip network hops (~15–40ms per call), and fails catastrophically under read/write bursts.
- ✅ **The Envelope Encryption Protocol**:
  1. **Key Encryption Key (KEK)**: Stored immutably inside the Cloud KMS or Hardware Security Module (HSM). The private key material never leaves the secure enclave boundary.
  2. **Data Encryption Key (DEK)**: Ephemeral, locally generated 256-bit symmetric key (AES-256 or ChaCha20).
  3. **Encryption Pipeline**:
     - Application calls `kms:GenerateDataKey` with the target `KeyId` and encryption context.
     - KMS returns the **Plaintext DEK** and the **Ciphertext DEK** (encrypted under KEK).
     - Application encrypts the application payload locally in RAM using the Plaintext DEK.
     - Application immediately zeroes and wipes the Plaintext DEK from memory buffers.
     - Store the `Encrypted_DEK` alongside the encrypted payload and IV.
  4. **Decryption Pipeline**:
     - Read the `Encrypted_DEK` from the storage record.
     - Call `kms:Decrypt(CiphertextBlob: Encrypted_DEK)` with the identical encryption context.
     - Decrypt payload in local memory using the returned Plaintext DEK, then immediately zeroize it.

```go
// Go: Production Envelope Encryption with AWS KMS v2 & AES-GCM
package crypto

import (
    "context"
    "crypto/aes"
    "crypto/cipher"
    "crypto/rand"
    "fmt"
    "io"

    "github.com/aws/aws-sdk-go-v2/service/kms"
    "github.com/aws/aws-sdk-go-v2/service/kms/types"
)

type EnvelopeService struct {
    kmsClient *kms.Client
    kekID     string
}

type EncryptedRecord struct {
    EncryptedDEK []byte `json:"encrypted_dek"`
    Nonce        []byte `json:"nonce"`
    Ciphertext   []byte `json:"ciphertext"` // Includes 128-bit authentication tag appended by GCM
}

func (s *EnvelopeService) EncryptPayload(ctx context.Context, plaintext []byte, tenantID string) (*EncryptedRecord, error) {
    // Cryptographic binding: EncryptionContext prevents cross-tenant ciphertext swapping
    encryptionContext := map[string]string{
        "tenant_id": tenantID,
        "purpose":   "pii_envelope_encryption",
    }

    dataKeyResp, err := s.kmsClient.GenerateDataKey(ctx, &kms.GenerateDataKeyInput{
        KeyId:             &s.kekID,
        KeySpec:           types.DataKeySpecAes256,
        EncryptionContext: encryptionContext,
    })
    if err != nil {
        return nil, fmt.Errorf("generate data key: %w", err)
    }

    // MANDATORY: Ensure Plaintext DEK is explicitly zeroed out when returning
    defer func() {
        for i := range dataKeyResp.Plaintext {
            dataKeyResp.Plaintext[i] = 0
        }
    }()

    block, err := aes.NewCipher(dataKeyResp.Plaintext)
    if err != nil {
        return nil, fmt.Errorf("new aes cipher: %w", err)
    }

    gcm, err := cipher.NewGCM(block)
    if err != nil {
        return nil, fmt.Errorf("new gcm: %w", err)
    }

    nonce := make([]byte, gcm.NonceSize()) // Standard 96-bit (12-byte) nonce
    if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
        return nil, fmt.Errorf("generate nonce: %w", err)
    }

    // Seal appends the ciphertext and the 16-byte authentication tag
    ciphertext := gcm.Seal(nil, nonce, plaintext, []byte(tenantID))

    return &EncryptedRecord{
        EncryptedDEK: dataKeyResp.CiphertextBlob,
        Nonce:        nonce,
        Ciphertext:   ciphertext,
    }, nil
}
```

---

## 2. AES-256-GCM Nonce / IV Reuse: The Catastrophic "Forbidden Attack"
In Galois/Counter Mode (GCM), encrypting two distinct plaintexts with the same key and the same 96-bit Initialization Vector (Nonce) is an unrecoverable cryptographic failure known as the **GCM Forbidden Attack**.

- ❌ **THE NONCE REUSE CATASTROPHE**:
  - GCM uses CTR (counter mode) for encryption combined with a GHASH authenticator polynomial.
  - If a $(Key, Nonce)$ pair is reused:
    $$C_1 = P_1 \oplus \text{AES}_K(\text{Nonce} \,\|\, 1), \quad C_2 = P_2 \oplus \text{AES}_K(\text{Nonce} \,\|\, 1)$$
    $$\implies C_1 \oplus C_2 = P_1 \oplus P_2$$
  - XORing the two ciphertexts completely strips away the encryption layer, leaving the XOR sum of the raw plaintexts.
  - Furthermore, subtracting the authentication equations solves the GHASH polynomial key $H$, enabling the attacker to forge valid authentication tags for arbitrary forged messages.
- ⚠️ **The Birthday Bound Trap with Random Nonces**:
  - A standard GCM nonce is 96 bits ($12 \text{ bytes}$).
  - According to the Birthday Paradox, when selecting nonces uniformly at random, the collision probability reaches $p \approx 10^{-6}$ after only $2^{32}$ (4.29 billion) encryptions under the exact same key.
  - NIST SP 800-38D explicitly mandates: **A single AES-GCM key MUST NOT be used with random nonces for more than $2^{32}$ invocations.**
- ✅ **The Two Production Remedies**:
  1. **Deterministic Nonce Construction (NIST SP 800-38D §8.2.1)**:
     - 32-bit fixed field (cluster node / worker process ID).
     - 64-bit invocation counter (monotonic atomic integer that never rolls over or resets during key lifetime).
  2. **Switch to Extended-Nonce XChaCha20-Poly1305**:
     - XChaCha20 utilizes a 192-bit ($24 \text{ byte}$) nonce.
     - With a 192-bit random nonce, the collision probability is $2^{-96}$, making random nonce generation safe for essentially infinite operations ($> 10^{20}$ records) without collision risk.

```go
// Go: Safe XChaCha20-Poly1305 with 192-bit CSPRNG Nonces (Eliminates Birthday Paradox Risk)
package crypto

import (
    "crypto/rand"
    "fmt"
    "io"

    "golang.org/x/crypto/chacha20poly1305"
)

func EncryptXChaCha20(key []byte, plaintext []byte, additionalData []byte) ([]byte, error) {
    if len(key) != chacha20poly1305.KeySize { // 32 bytes
        return nil, fmt.Errorf("invalid key size: got %d, want 32", len(key))
    }

    aead, err := chacha20poly1305.NewX(key)
    if err != nil {
        return nil, fmt.Errorf("init xchacha20: %w", err)
    }

    // 192-bit nonce (24 bytes): mathematically immune to random collision attack
    nonce := make([]byte, aead.NonceSize())
    if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
        return nil, fmt.Errorf("read random nonce: %w", err)
    }

    // Prefix ciphertext with the 24-byte nonce
    ciphertext := aead.Seal(nonce, nonce, plaintext, additionalData)
    return ciphertext, nil
}
```

---

## 3. Secret Zeroization & Memory Safety: The In-Process Garbage Heap Trap
Standard application runtimes (Go, Node.js, Python, Java) manage memory via automated Garbage Collection (GC). GC frees memory asynchronously and does **not** erase or overwrite old memory contents.

- ❌ **THE GC RESIDUAL SECRET LEAK**:
  - Creating a secret as an immutable string (`apiKey := "sk_live_xyz"`) allocates a heap buffer.
  - When the string leaves scope, it remains in physical RAM uninitialized until another allocation happens to overwrite that memory address.
  - If a core dump is triggered, swap memory is paged to disk, or an attacker exploits an out-of-bounds memory read (Heartbleed-style) or inspects `/proc/$PID/mem`, the secret is recovered in plaintext.
- ✅ **The Memory Zeroization Invariants**:
  1. **Never store secrets as immutable strings**: Always accept and process cryptographic keys and passwords as mutable byte slices (`[]byte` in Go, `Uint8Array` / `Buffer` in Node.js, `bytearray` in Python).
  2. **Immediate Deterministic Zeroing**: Wipe sensitive buffers immediately after use in a `defer` block or `finally` clause.
  3. **Prevent Compiler Optimization Elision**: Standard compilers may elide dead writes (`memset(buf, 0, len)`) if the buffer is never read again. Use compiler-resistant zeroing primitives (`crypto/subtle`, `Zeroize`).
  4. **Lock RAM Pages via `mlock(2)`**: In high-security enclaves, call `mlock` on memory holding master keys to prevent the operating system kernel from writing keys to swap partitions on disk.

```go
// Go: Zeroization & Memory Overwrite Invariant
package crypto

import (
    "crypto/subtle"
)

// Zeroize securely wipes a byte slice in place, defeating dead-store elimination
func Zeroize(buf []byte) {
    if len(buf) == 0 {
        return
    }
    // Go 1.21+ clear built-in zeroes slices
    clear(buf)
    // Extra barrier against aggressive compiler optimization
    subtle.ConstantTimeByteEq(buf[0], 0)
}
```

```ts
// TypeScript / Node.js: Safe Buffer Zeroization
export function wipeBuffer(buf: Buffer | Uint8Array): void {
  // Overwrite entire memory space with zeros in-place
  buf.fill(0);
}

// Example usage:
export async function verifySignature(secretKey: Buffer, payload: Buffer): Promise<boolean> {
  const ephemeralKey = Buffer.from(secretKey);
  try {
    return computeHMAC(ephemeralKey, payload);
  } finally {
    // Guaranteed memory wipe regardless of exceptions
    wipeBuffer(ephemeralKey);
  }
}
```

---

## 4. The Environment Variable Secret Leak Anti-Pattern
Injecting secrets into long-running applications via OS environment variables (`export DATABASE_PASSWORD="secret"`) is one of the most common and dangerous security anti-patterns in cloud-native infrastructure.

- ❌ **Why Environment Variables Are Unsafe for Secrets**:
  1. **Process Inheritance**: Every child process spawned via `fork()`, `exec()`, or sub-shell invocation inherits all environment variables of the parent process. A compromised CLI tool, linter, or build script gains immediate access to all production credentials.
  2. **Diagnostic & Crash Dumps**: Application Performance Monitoring (APM) tools, exception catchers (Sentry, Bugsnag), and crash logs frequently serialize `process.env` or `os.Environ()` into error diagnostic payloads sent over the wire.
  3. **Kernel Procfs Exposure**: On Linux, `/proc/$PID/environ` exposes all environment variables of any running process to any process running under the same UID or with `ptrace` permissions.
  4. **SSRF Framework Endpoints**: Popular microservice frameworks frequently expose environment diagnostics (e.g., Spring Boot Actuator `/actuator/env`, Node.js debug dumps) via accidental SSRF or unauthenticated internal routing.
- ✅ **The Secure Secret Delivery Hierarchy**:
  1. **RAM-backed Filesystem Mounts (`tmpfs`)**: Inject secrets into an ephemeral in-memory filesystem (e.g., Kubernetes `Secret` volume mounted at `/var/run/secrets/`, which backs to `tmpfs`). Memory never touches physical disk storage.
  2. **Dynamic JIT Retrieval via Workload Identity**: Application uses platform workload identity (AWS IAM Roles for Service Accounts / GCP Workload Identity / Azure Managed Identity) to dynamically retrieve ephemeral tokens directly over mTLS.
  3. **Periodic Secret Reloading**: Read secret files from disk periodically or watch filesystem events (`inotify`) to support rotation without process restarts.

---

## 5. HashiCorp Vault Dynamic Ephemeral Database Credentials
Static, long-lived database credentials (`app_user:master_password_2024`) shared across dozens of container instances create an enormous blast radius upon breach and make non-disruptive rotation nearly impossible.

- ❌ **THE STATIC CREDENTIAL DISASTER**:
  - A leaked connection string in an unversioned backup, compromised developer workstation, or log file gives attackers permanent, untracked access to the database until someone manually changes the password and orchestrates a coordinated redeploy of all microservices.
- ✅ **The Dynamic Vault Invariant**:
  - The application authenticates to Vault using its Kubernetes Service Account JWT or AWS IAM role.
  - The application requests a database credential with a short time-to-live (e.g., `TTL = 15m`).
  - Vault dynamically executes a DDL template on the target PostgreSQL cluster:
    ```sql
    CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "{{name}}";
    ```
  - The application maintains a background lease-renewal loop that periodically invokes Vault's renewal endpoint at $2/3$ of the lease lifetime.
  - When the pod shuts down, it immediately revokes the lease; if a node crashes, Vault automatically executes `DROP ROLE` upon lease expiry.

```go
// Go: Vault Dynamic Lease Auto-Renewal Loop
package secrets

import (
    "context"
    "fmt"
    "log/slog"
    "time"

    vault "github.com/hashicorp/vault/api"
)

type DynamicDBLeaseManager struct {
    client *vault.Client
    logger *slog.Logger
}

func (m *DynamicDBLeaseManager) MaintainDatabaseLease(ctx context.Context, secret *vault.Secret) {
    leaseID := secret.LeaseID
    leaseDuration := time.Duration(secret.LeaseDuration) * time.Second

    // Renew at 2/3 of the lease duration to avoid race conditions
    renewInterval := (leaseDuration * 2) / 3
    if renewInterval < 10*time.Second {
        renewInterval = 10 * time.Second
    }

    ticker := time.NewTicker(renewInterval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            // Graceful shutdown: revoke dynamic credentials immediately
            m.logger.Info("revoking dynamic vault lease on shutdown", "lease_id", leaseID)
            revokeCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            defer cancel()
            _ = m.client.Sys().RevokeWithContext(revokeCtx, leaseID)
            return

        case <-ticker.C:
            renewed, err := m.client.Sys().RenewWithContext(ctx, leaseID, int(secret.LeaseDuration))
            if err != nil {
                m.logger.Error("failed to renew dynamic database lease", "lease_id", leaseID, "err", err)
                // Attempt rapid retry before expiration
                time.Sleep(5 * time.Second)
                continue
            }
            m.logger.Debug("dynamic lease renewed successfully", "lease_id", leaseID, "ttl", renewed.LeaseDuration)
        }
    }
}
```

---

## 6. Zero-Downtime Secret & Key Rotation: The 3-Key Window
Hardcoding a single symmetric key or updating a secret in place creates a catastrophic split-brain dilemma: any data encrypted with the old key becomes instantly unreadable, or services reject tokens signed during deployment cutovers.

- ❌ **THE BIG-BANG KEY SWAP TRAP**:
  - Flipping a key in production instantly breaks all in-flight requests, pending webhooks, cached sessions, and unmigrated database records.
- ✅ **The 3-Key Lifecycle Model**:
  Every cryptographic subsystem must support a sliding window of at least three key states:
  1. **Active (`current`)**: The only key used to encrypt new records or sign new tokens.
  2. **Deprecated / Valid (`previous`)**: Accepted strictly for *decryption* or signature *verification*. Never used for new encryptions.
  3. **Pending (`next`)**: Pre-distributed across instances before becoming active, ensuring no instance rejects a key before full cluster propagation.
  4. **Revoked / Purged**: Permanently invalid. Any ciphertext tagged with this key is rejected.

### Serialized Ciphertext Format Standard
Never store raw encrypted bytes without explicit key and algorithm metadata. Always prepend an authenticated metadata envelope:

$$\text{Ciphertext Record} = \text{Version} \,\|\, \text{KeyID} \,\|\, \text{Nonce} \,\|\, \text{Ciphertext} \,\|\, \text{AuthTag}$$

```
+------------+--------------------+----------------+---------------------------+----------------+
| Version: 1B| KeyID: 8B (uint64) | Nonce: 12B-24B | Ciphertext: N Bytes       | Tag: 16B       |
+------------+--------------------+----------------+---------------------------+----------------+
```

```go
// Go: Multi-Key Decryption Router Supporting Zero-Downtime Rotation
package crypto

import (
    "encoding/binary"
    "errors"
    "fmt"
    "sync"
)

var (
    ErrUnknownKeyID   = errors.New("crypto: unknown key id")
    ErrPayloadTooShort = errors.New("crypto: payload too short for envelope header")
)

type KeyRing struct {
    mu         sync.RWMutex
    activeKeyID uint64
    keys        map[uint64][]byte // keyID -> 32-byte symmetric key
}

func (kr *KeyRing) Decrypt(record []byte) ([]byte, error) {
    // Header format: [Version: 1 byte][KeyID: 8 bytes][Payload...]
    if len(record) < 1+8+12+16 {
        return nil, ErrPayloadTooShort
    }

    version := record[0]
    if version != 1 {
        return nil, fmt.Errorf("unsupported envelope version: %d", version)
    }

    keyID := binary.BigEndian.Uint64(record[1:9])

    kr.mu.RLock()
    key, exists := kr.keys[keyID]
    kr.mu.RUnlock()

    if !exists {
        return nil, fmt.Errorf("%w: key_id=%d", ErrUnknownKeyID, keyID)
    }

    // Decrypt using the specific historical key identified by keyID
    return DecryptAESGCM(key, record[9:])
}
```

---

## 7. Field-Level Encryption (FLE) & Blind Indexing for Searchable PII
Under GDPR, HIPAA, and PCI-DSS, sensitive fields (Social Security Numbers, National IDs, credit card primary account numbers, bank accounts) must be encrypted at rest in the database.

- ❌ **THE BLIND ENCRYPTION TRAP**:
  - Secure symmetric encryption (AES-GCM) requires a unique non-deterministic nonce for every write.
  - As a result, encrypting `"123-45-6789"` twice yields two completely different ciphertexts:
    $$\text{Encrypt}("123-45-6789") \to \texttt{a8f2...}$$
    $$\text{Encrypt}("123-45-6789") \to \texttt{3b7c...}$$
  - A query like `SELECT * FROM users WHERE ssn = :query` becomes completely impossible without performing a devastating full table scan and decrypting every single row in memory.
- ❌ **THE INSECURE DETERMINISTIC ENCRYPTION TRAP**:
  - Encrypting with a fixed nonce (Deterministic AES-SIV or AES-ECB) makes ciphertexts searchable via exact match, but directly leaks data distribution, frequency analysis, and enables cross-table correlation attacks.
- ✅ **The Blind Index Protocol**:
  1. Store the sensitive payload as a standard non-deterministic ciphertext (`encrypted_ssn`).
  2. Compute an isolated **Blind Index** in an adjacent column (`ssn_bidx`) using a completely separate secret key (`BLIND_INDEX_KEY`) and HMAC-SHA256:
     $$\text{BlindIndex}(x) = \text{Truncate}_{128}\Big(\text{HMAC-SHA256}\big(K_{\text{bidx}}, \, \text{normalize}(x)\big)\Big)$$
  3. Pre-process the input value (strip spaces, dashes, convert to lowercase) before hashing to ensure exact match consistency.
  4. Querying by SSN computes the blind index of the query target and searches the indexed column:
     ```sql
     -- O(1) B-tree indexed exact search with zero plaintext exposure
     SELECT id, encrypted_ssn, encrypted_payload 
     FROM users 
     WHERE ssn_bidx = :computed_blind_index;
     ```
  5. The primary database contains zero knowledge of the raw SSN and cannot reverse the HMAC without the external $K_{\text{bidx}}$.

```go
// Go: Blind Index Generation with Domain Separation
package crypto

import (
    "crypto/hmac"
    "crypto/sha256"
    "encoding/hex"
    "strings"
)

type BlindIndexer struct {
    blindKey []byte
}

func NewBlindIndexer(key []byte) *BlindIndexer {
    return &BlindIndexer{blindKey: key}
}

func (bi *BlindIndexer) ComputeIndex(fieldName, rawValue string) string {
    // 1. Normalize value
    normalized := strings.TrimSpace(strings.ToLower(rawValue))
    
    // 2. Domain separation prevents hash cross-correlation across different columns
    mac := hmac.New(sha256.New, bi.blindKey)
    mac.Write([]byte(fieldName + ":" + normalized))
    sum := mac.Sum(nil)

    // 3. Truncate to 16 bytes (128 bits) to save index storage while maintaining collision resistance
    return hex.EncodeToString(sum[:16])
}
```

---

## 8. Timing-Safe Secret Comparisons & Constant-Time Invariants
Standard language string equality operators (`tokenA == tokenB` or `strcmp(a, b)`) execute **short-circuit evaluation**: they compare bytes sequentially from left to right and abort execution on the first mismatched byte.

- ❌ **THE TIMING LEAK VULNERABILITY**:
  - An attacker measuring network round-trip times down to microsecond/nanosecond fidelity can guess a secret byte-by-byte:
    - `"a..."` rejects in $1.2\mu\text{s}$ (first byte mismatch).
    - `"b..."` rejects in $2.4\mu\text{s}$ (first byte matches, second byte mismatch).
  - This allows recovering HMAC signatures, API keys, and session tokens without brute-forcing the $2^{256}$ keyspace.
- ✅ **The Constant-Time Invariants**:
  1. Always compare cryptographic hashes, HMAC tags, authorization tokens, and API keys using constant-time algorithms that execute in identical clock cycles regardless of byte match positions.
  2. Never leak length differences: ensure length checks also execute in constant time or pre-hash inputs with SHA-256 before comparison.

| Language | Prohibited Anti-Pattern | Mandatory Constant-Time Primitive |
| :--- | :--- | :--- |
| **Go** | `tokenA == tokenB` / `bytes.Equal(a, b)` | `subtle.ConstantTimeCompare(a, b) == 1` |
| **TypeScript / Node** | `tokenA === tokenB` | `crypto.timingSafeEqual(bufA, bufB)` |
| **Rust** | `token_a == token_b` | `subtle::ConstantTimeEq::ct_eq(&a, &b).into()` |
| **Python** | `token_a == token_b` | `hmac.compare_digest(token_a, token_b)` |

```go
// Go: Constant-time authentication token validation
func ValidateWebhookSignature(expectedMAC, actualMAC []byte) bool {
    if len(expectedMAC) != len(actualMAC) {
        // Pre-hash to avoid leaking length via early return
        hExpected := sha256.Sum256(expectedMAC)
        hActual := sha256.Sum256(actualMAC)
        return subtle.ConstantTimeCompare(hExpected[:], hActual[:]) == 1
    }
    return subtle.ConstantTimeCompare(expectedMAC, actualMAC) == 1
}
```

---

## 9. JWKS (JSON Web Key Set) Public Key Verification & Caching Hygiene
Modern identity architectures (OAuth 2.1, OIDC, Auth0, Okta, AWS Cognito) publish public verification keys via dynamic endpoints (`/.well-known/jwks.json`). Handling these keys improperly opens severe Denial of Service (DoS) and Spoofing vulnerabilities.

- ❌ **THE SYNCHRONOUS UNCACHED JWKS DOS VULNERABILITY**:
  - Fetching the JWKS URL synchronously on every incoming authenticated API request adds 50–200ms latency to every call and fails completely if the Identity Provider (IdP) experiences an outage.
  - Even worse: if the service re-fetches the JWKS whenever a token arrives with an unknown `kid` (Key ID), an attacker can flood the API with tokens containing random `kid` values, causing the service to launch a distributed denial of service against its own IdP.
- ✅ **The JWKS Caching & Circuit-Breaker Invariants**:
  1. **In-Memory Cache with Strict TTL**: Cache public keys in memory for 1–24 hours.
  2. **Rate-Limited JIT Refresh**: If a valid token arrives with an unknown `kid` (valid during an active key rotation event at the IdP), trigger a background refresh **at most once every 5 minutes**.
  3. **Singleflight Coalescing**: Ensure concurrent requests encountering a cache miss do not spawn duplicate HTTP requests to the IdP endpoint.
  4. **Algorithm Whitelist Pinning**: Reject tokens whose `alg` header does not strictly match the expected algorithm (e.g., mandate `RS256` or `EdDSA`; strictly prohibit `HS256` or `none`).

```go
// Go: Hardened JWKS Key Cache with Singleflight and Cooldown Protection
package auth

import (
    "context"
    "errors"
    "fmt"
    "sync"
    "time"

    "golang.org/x/sync/singleflight"
)

var ErrKeyNotFound = errors.New("jwks: key id not found")

type JWKSCache struct {
    jwksURL       string
    mu            sync.RWMutex
    keys          map[string]any // kid -> crypto.PublicKey
    lastFetched   time.Time
    cooldownPeriod time.Duration
    sfGroup       singleflight.Group
}

func NewJWKSCache(jwksURL string) *JWKSCache {
    return &JWKSCache{
        jwksURL:        jwksURL,
        keys:           make(map[string]any),
        cooldownPeriod: 5 * time.Minute,
    }
}

func (c *JWKSCache) GetKey(ctx context.Context, kid string) (any, error) {
    c.mu.RLock()
    key, exists := c.keys[kid]
    lastFetch := c.lastFetched
    c.mu.RUnlock()

    if exists {
        return key, nil
    }

    // Key not found in cache. Check if we are within the cooldown window
    if time.Since(lastFetch) < c.cooldownPeriod {
        return nil, fmt.Errorf("%w: %s (cooldown active, skipping fetch)", ErrKeyNotFound, kid)
    }

    // Coalesce concurrent fetches using singleflight
    _, err, _ := c.sfGroup.Do("fetch_jwks", func() (any, error) {
        return nil, c.refreshKeys(ctx)
    })
    if err != nil {
        return nil, fmt.Errorf("refresh jwks: %w", err)
    }

    c.mu.RLock()
    defer c.mu.RUnlock()
    key, exists = c.keys[kid]
    if !exists {
        return nil, fmt.Errorf("%w: %s (after refresh)", ErrKeyNotFound, kid)
    }
    return key, nil
}

func (c *JWKSCache) refreshKeys(ctx context.Context) error {
    // Perform HTTP GET with timeout, parse JSON, populate c.keys, update c.lastFetched
    // ...
    return nil
}
```

---

## 10. Cryptographic Invariants Checklist for Agentic Code Review
When reviewing, designing, or generating cryptographic and secret management code, enforce this checklist:

- [ ] **Envelope Architecture**: Is high-volume data encrypted locally using ephemeral DEKs with Cloud KMS/HSM holding strictly the KEK?
- [ ] **GCM Nonce Safety**: Are 96-bit AES-GCM nonces mathematically guaranteed never to repeat under the same key? Has XChaCha20-Poly1305 (192-bit nonce) been considered for high-scale systems?
- [ ] **Memory Zeroing**: Are raw byte keys, decrypted payloads, and token buffers wiped with `clear()` / zeroization immediately after use?
- [ ] **No Secrets in Environment**: Are production secrets delivered via memory mounts (`tmpfs`) or JIT dynamic identities rather than static `process.env`?
- [ ] **Dynamic Leases**: Are database passwords ephemeral with dynamic rotation and auto-revocation via Vault or Cloud IAM?
- [ ] **Key Rotation Envelope**: Does ciphertext include explicit `Version` and `KeyID` headers to enable zero-downtime key rotation?
- [ ] **Searchable PII**: Is sensitive searchable data decoupled into non-deterministic ciphertext and an isolated blind index (HMAC-SHA256)?
- [ ] **Constant-Time Verification**: Are all HMAC, token, and hash comparisons performed using constant-time equality primitives?
- [ ] **JWKS DoS Protection**: Is public key discovery cached with rate-limited refresh and singleflight coalescing?
- [ ] **Encryption Context**: Is all KMS encryption bound to immutable context attributes (`tenant_id`, `purpose`) to prevent cross-tenant record swapping?
