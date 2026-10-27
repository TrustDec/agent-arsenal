---
description: Agentic webhooks, cryptographic HMAC-SHA256 signature verification, raw-body byte preservation, timing-safe equality, replay attack prevention, asynchronous two-phase ingestion FSM, transactional outbox dispatch, and dead-letter queue (DLQ) lifecycle across Claude Code, Cursor, Windsurf, Devin, Roo Code, and Pi
globs: **/*{webhook,hook,signature,hmac,ingestion,dispatch,event-delivery,outbox}*.*,**/api/**/*webhook*.*,**/routes/**/*webhook*.*,**/services/**/*.{ts,js,py,go},**/handlers/**/*.{ts,js,py,go}
alwaysApply: false
---

# Agentic Webhooks, Cryptographic Signature Verification & Resilient Event Delivery Invariants

> Add these rules to your project when utilizing autonomous coding agents (Claude Code, Cursor Composer, Windsurf Cascade, Devin, Roo Code, Pi, OpenCode, SWE-bench) to design inbound webhook ingestion endpoints (Stripe, GitHub, Shopify, Twilio, Slack, Clerk, Supabase, Anthropic/OpenAI batch webhooks) or outbound event-driven webhook dispatchers. Eliminate the "Raw-Body Deserialization Mutation Trap" (where JSON middleware modifies raw payload bytes breaking HMAC validation), the "Timing-Attack Side-Channel Vulnerability" (where string equality `===` leaks signature bytes), the "Replay Attack & Timestamp Expiry Trap" (where un-timestamped payloads are replayed by adversaries), the "Synchronous Processing / 504 Gateway Timeout Cascade" (where slow downstream operations cause upstream providers to fire thundering herd retry storms), the "Dual-Write Phantom Webhook Leak" (where outbound webhooks escape before database transactions commit), and the "Single-Key Rotation Outage" by establishing a strict 5-Tier Webhook Security & Resilient Delivery Ladder, constant-time verification primitives, asynchronous two-phase ingestion FSM, transactional outbox dispatch, and dual-key graceful secret rotation.

---

## 1. Architectural Taxonomy: The 6 Webhook Catastrophes vs The 5-Tier Webhook Governance Ladder

When autonomous coding agents are instructed to "handle Stripe webhooks", "receive GitHub event notifications", or "dispatch webhooks to customer endpoints", LLMs almost universally generate naive synchronous handlers:
```typescript
// ❌ CATASTROPHIC LLM WEBHOOK IMPLEMENTATION
app.post('/api/webhooks', async (req, res) => {
  const sig = req.headers['x-signature'];
  const computed = crypto.createHmac('sha256', process.env.WEBHOOK_SECRET)
                         .update(JSON.stringify(req.body)).digest('hex');
  if (sig !== computed) return res.status(401).send('Bad Sig'); // VULN 1 & 2
  await processHeavyBilling(req.body); // VULN 3: Synchronous timeout
  await sendCustomerEmails(req.body);
  res.json({ ok: true });
});
```

In production distributed systems, this naive pattern produces six critical engineering failures:

- **The "Raw-Body Deserialization Mutation Trap"**:
  - Webhook signatures are computed by the provider over the *exact, byte-for-byte stream* transmitted over the wire.
  - When agents configure standard HTTP frameworks (Express, Fastify, Next.js, Koa, Django, Flask, Gin), incoming bodies are automatically parsed into in-memory JSON objects.
  - Calling `JSON.stringify(req.body)` afterwards does **not** restore the original byte stream: key order can change, whitespace and newlines are stripped or altered, Unicode sequences are re-encoded, and floating-point representations differ.
  - Result: $\text{HMAC}(K, \text{RawBytes}) \neq \text{HMAC}(K, \text{JSON.stringify}(\text{req.body}))$. In Express, global `express.json()` middleware drains the request stream, irreversibly destroying raw bytes and causing 100% of authentic provider webhooks to fail validation in production.
- **The "Timing-Attack Side-Channel Comparison Vulnerability"**:
  - Autonomous agents verify cryptographic signatures using standard equality operators (`receivedSig === computedSig` or `sigA == sigB`).
  - Standard string comparison algorithms terminate execution upon encountering the first non-matching byte. An adversary measuring response latency over thousands of requests can measure microsecond differences to deduce signature bytes sequentially from left to right.
  - Invariant: Signature comparison MUST execute in constant time via `crypto.timingSafeEqual` (Node.js), `crypto.subtle.timingSafeEqual` (Web Crypto), or `hmac.Equal` (Go). Furthermore, length mismatches must be checked carefully to prevent runtime exceptions that leak length information.
- **The "Replay Attack & Timestamp Expiry Trap"**:
  - Even if an HMAC signature is mathematically valid, an attacker with network inspection capabilities (or access to compromised proxy logs) can capture the raw payload and signature headers.
  - If the agent does not enforce a bounded temporal acceptance window ($|t_{\text{current}} - t_{\text{hook}}| \le \Delta t_{\text{max}}$, typically $300\text{ seconds}$), the adversary can replay the webhook days or weeks later—crediting customer accounts or generating duplicate orders repeatedly.
  - Furthermore, if the agent lacks an atomic deduplication store, multiple identical payloads replayed within the valid time window will be executed concurrently.
- **The "Synchronous Ingestion & 504 Gateway Timeout Avalanche"**:
  - External providers enforce aggressive delivery timeouts: Stripe cancels requests after 10 seconds, GitHub after 10 seconds, and Shopify after 5 seconds.
  - When agents execute database updates, third-party API calls, PDF rendering, or email dispatch inside the synchronous HTTP request handler, any transient downstream slowdown causes the handler to exceed the provider's timeout.
  - The provider marks the delivery as failed and immediately initiates automated retry schedules (e.g., Stripe retries up to 3 days with exponential backoff). The incoming retries compound the existing bottleneck, exhausting connection pools and taking down the entire web cluster.
  - Invariant: **The Two-Phase Ingestion Axiom**: Webhook ingestion must be asynchronous. Phase 1 (Signature Verification + Atomic Append to Ingestion Ledger) MUST complete in $<100\text{ms}$ and return HTTP `200 OK` or `202 Accepted`. Phase 2 executes the business logic decoupled via durable worker queues.
- **The "Dual-Write Phantom Webhook Leak"**:
  - When agents implement outbound webhook dispatchers, they often place `fetch(subscriberUrl)` calls directly inside database transactions:
    ```go
    // ❌ PHANTOM WEBHOOK ANTI-PATTERN
    tx, _ := db.Begin(ctx)
    tx.Exec(ctx, "UPDATE invoices SET status = 'paid' WHERE id = $1", invoiceID)
    webhookClient.Send(ctx, "invoice.paid", payload) // SENDS OVER HTTP
    if err := tx.Commit(ctx); err != nil {           // COMMIT FAILS!
        // Disaster: Customer received webhook for an invoice that was NEVER marked paid!
    }
    ```
  - If the transaction rolls back due to a serialization conflict, lock timeout, or constraint failure, the webhook has already escaped into the wild, producing irreversible phantom state in customer systems.
  - Invariant: Outbound webhooks MUST use the **Transactional Outbox Pattern**: the event is written to an `outbox_webhooks` table inside the *same* atomic database transaction. A separate relay worker dispatches the event only after the transaction is durably committed.
- **The "Single-Key Rotation Outage"**:
  - When webhook signing secrets are rotated (due to compliance schedules or credential compromise), providers support a dual-key transition window where payloads may be signed with either the retiring key or the newly generated key.
  - Agents that configure a single static `WEBHOOK_SECRET` reject all incoming events during the rotation phase until the environment variable is updated and deployed, creating an unavoidable production outage.
  - Invariant: Webhook verification engines MUST accept a collection of active candidate secrets $\{K_{\text{current}}, K_{\text{previous}}\}$ and succeed if *any* valid secret matches the signature.

---

### The 5-Tier Webhook Security & Resilient Delivery Ladder

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Tier 4: Outbound Transactional Outbox, Jittered Backoff & DLQ Lifecycle     │
│         Transactional outbox durability P(DB ⊕ Outbox) ≡ 0; decorrelated    │
│         jitter retry scheduling; automatic circuit-breaking subscriber DLQ   │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 3: Two-Phase Asynchronous Ingestion & Sub-100ms ACK                    │
│         Verify & enqueue raw event into durable ledger in <50ms; return 202;│
│         asynchronous worker execution decoupled from HTTP gateway connection│
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 2: Bounded Temporal Skew Sentinels & Atomic Deduplication Ledgers      │
│         Enforce |t_now - t_hook| ≤ 300s; reserve (source, event_id) via     │
│         INSERT ... ON CONFLICT DO NOTHING before processing                 │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 1: Constant-Time HMAC Verification & Zero-Downtime Dual-Key Rotation   │
│         crypto.timingSafeEqual / hmac.Equal; multi-secret candidate match;  │
│         zero-exception length guardrails preventing timing side-channels    │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tier 0: Raw-Byte Preserving Transport & Bounded Stream Invariants           │
│         Raw buffer capture before deserialization; strict body size limits  │
│         (MaxBodyBytes = 1MB) preventing Memory Exhaustion DoS attacks       │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Mathematical & Formal Invariant Calculus

### 2.1 The Cryptographic Signature Equation

Let $P_{\text{raw}}$ be the exact byte array of the incoming HTTP request body, $t_{\text{header}} \in \mathbb{N}$ be the Unix timestamp extracted from the signature header, and $K \in \mathcal{K}$ be a secret key.

The canonical signature scheme constructs the message digest $M$ as:
$$M = t_{\text{header}} \mathbin{\Vert} \text{'.' } \mathbin{\Vert} P_{\text{raw}}$$

The expected HMAC signature $S_{\text{expected}}$ is defined as:
$$S_{\text{expected}} = \text{HMAC-SHA256}(K, M)$$

For hexadecimal string representations with length $L = 64$ characters, constant-time verification over received signature $S_{\text{received}}$ and computed $S_{\text{expected}}$ must satisfy:
$$\text{Equal}_{\text{constant-time}}(A, B) = \begin{cases}
\text{false} & \text{if } |A| \neq |B| \\
\left( \bigvee_{i=0}^{|A|-1} (A[i] \oplus B[i]) \right) == 0 & \text{if } |A| = |B|
\end{cases}$$

To prevent timing leaks on length mismatches, the length check itself must be evaluated before the XOR accumulator, or both buffers must be padded to a fixed maximum length prior to constant-time evaluation.

### 2.2 The Temporal Tolerance Invariant

Let $t_{\text{wall}}$ be the current monotonic wall-clock time of the receiving server and $\Delta t_{\text{tolerance}}$ be the maximum permissible clock skew (standard: $300\text{ seconds} = 5\text{ minutes}$).

A webhook request is admissible if and only if:
$$|t_{\text{wall}} - t_{\text{header}}| \le \Delta t_{\text{tolerance}}$$

$$\text{Admissible}(t_{\text{header}}) = \begin{cases}
1 & \text{if } t_{\text{wall}} - \Delta t_{\text{tolerance}} \le t_{\text{header}} \le t_{\text{wall}} + \Delta t_{\text{tolerance}} \\
0 & \text{otherwise (reject with HTTP 400 Bad Request)}
\end{cases}$$

### 2.3 The Dual-Key Secret Verification Function

Let $\mathcal{K}_{\text{active}} = \{K_1, K_2, \dots, K_n\}$ be the set of valid signing keys configured during secret rotation (where $|\mathcal{K}_{\text{active}}| \ge 1$, typically current and retiring secrets).

The multi-key verification predicate $\mathcal{V}(P_{\text{raw}}, t_{\text{header}}, S_{\text{received}}, \mathcal{K}_{\text{active}})$ is:
$$\mathcal{V} = \bigvee_{K \in \mathcal{K}_{\text{active}}} \text{Equal}_{\text{constant-time}}\Big( S_{\text{received}}, \, \text{HMAC-SHA256}(K, \, t_{\text{header}} \mathbin{\Vert} \text{'.' } \mathbin{\Vert} P_{\text{raw}}) \Big)$$

If $|\mathcal{K}_{\text{active}}| = 0$, the server must fail closed and reject all requests.

### 2.4 The Truncated Exponential Backoff with Decorrelated Jitter

For outbound webhook delivery to subscriber endpoints, retry delays $t_{k}$ for attempt $k \in \{1, 2, \dots, K_{\text{max}}\}$ are computed using full decorrelated jitter to prevent synchronized retry stampedes:
$$t_0 = t_{\text{base}}$$
$$t_{k+1} = \min\Big( t_{\text{max}}, \, \text{Uniform}(t_{\text{base}}, \, t_k \times 3) \Big)$$
where $t_{\text{base}} = 5\text{s}$, $t_{\text{max}} = 86400\text{s}$ (24 hours), and $K_{\text{max}} = 10$.

### 2.5 Dead Letter Queue (DLQ) & Subscription Suspension Calculus

Let $\mathcal{E}$ be an outbound webhook delivery. The event transitions to the Dead Letter Queue when:
$$\text{State}(\mathcal{E}) \leftarrow \text{DLQ} \iff \text{AttemptCount}(\mathcal{E}) \ge K_{\text{max}} \land \text{Status}(\mathcal{E}) \neq \text{Delivered}$$

Let $F_{\text{consecutive}}(S)$ be the count of consecutive failed deliveries to subscriber $S$. The subscriber status transitions to $\text{Suspended}$ when:
$$\text{Status}(S) \leftarrow \text{Suspended} \iff F_{\text{consecutive}}(S) \ge N_{\text{threshold}} \quad (N_{\text{threshold}} = 50)$$

---

## 3. Multi-Language Production Invariants & Code Patterns

### 3.1 Go: Preserving Raw Body & Constant-Time Ingestion (`net/http`)

```go
package webhooks

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	MaxWebhookBodyBytes = 1 << 20 // 1 MB strict upper bound
	DefaultTimeSkewSec  = 300     // 5 minutes tolerance
)

type WebhookReceiver struct {
	db      *pgxpool.Pool
	secrets []string
}

func NewWebhookReceiver(db *pgxpool.Pool, secrets []string) (*WebhookReceiver, error) {
	if len(secrets) == 0 {
		return nil, errors.New("webhook receiver requires at least one signing secret")
	}
	return &WebhookReceiver{db: db, secrets: secrets}, nil
}

// ServeHTTP implements the Two-Phase Ingestion Invariant:
// Phase 1: Verify HMAC + capture raw body + insert into deduplication table (<50ms).
// Phase 2: Decoupled background worker executes business logic.
func (wr *WebhookReceiver) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	// 1. Strict bounded read to prevent Memory Exhaustion DoS
	limitedReader := io.LimitReader(r.Body, MaxWebhookBodyBytes+1)
	rawBody, err := io.ReadAll(limitedReader)
	if err != nil {
		http.Error(w, "Failed reading request body", http.StatusBadRequest)
		return
	}
	if len(rawBody) > MaxWebhookBodyBytes {
		http.Error(w, "Request body exceeds 1MB limit", http.StatusRequestEntityTooLarge)
		return
	}

	// 2. Parse Signature Header (Format: t=1614...,v1=hexsignature)
	sigHeader := r.Header.Get("Stripe-Signature")
	if sigHeader == "" {
		sigHeader = r.Header.Get("X-Hub-Signature-256")
	}
	if sigHeader == "" {
		http.Error(w, "Missing webhook signature header", http.StatusUnauthorized)
		return
	}

	timestamp, receivedSig, err := parseSignatureHeader(sigHeader)
	if err != nil {
		http.Error(w, "Malformed signature header", http.StatusBadRequest)
		return
	}

	// 3. Enforce Temporal Tolerance Window (|t_now - t_header| <= 300s)
	now := time.Now().Unix()
	if math.Abs(float64(now-timestamp)) > DefaultTimeSkewSec {
		http.Error(w, "Webhook timestamp outside tolerance window", http.StatusBadRequest)
		return
	}

	// 4. Constant-Time Verification across candidate secrets (Zero-Downtime Rotation)
	if !wr.verifySignature(rawBody, timestamp, receivedSig) {
		http.Error(w, "Invalid cryptographic signature", http.StatusUnauthorized)
		return
	}

	eventID := r.Header.Get("X-Webhook-ID")
	if eventID == "" {
		// Fallback to deterministic SHA-256 hash of payload as deduplication key
		h := sha256.Sum256(rawBody)
		eventID = hex.EncodeToString(h[:])
	}

	// 5. Atomic Ingestion Reservation (INSERT ... ON CONFLICT DO NOTHING)
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()

	tag, err := wr.db.Exec(ctx, `
		INSERT INTO webhook_inbound_events (
			event_id, source, raw_payload, status, received_at
		) VALUES ($1, $2, $3, 'pending', NOW())
		ON CONFLICT (source, event_id) DO NOTHING;
	`, eventID, "stripe", rawBody)

	if err != nil {
		http.Error(w, "Database persistence error", http.StatusInternalServerError)
		return
	}

	// 6. Return immediate 202 Accepted (<50ms). Never execute business logic here!
	w.WriteHeader(http.StatusAccepted)
	if tag.RowsAffected() == 0 {
		_, _ = w.Write([]byte(`{"status":"duplicate_ignored"}`))
	} else {
		_, _ = w.Write([]byte(`{"status":"accepted"}`))
	}
}

func (wr *WebhookReceiver) verifySignature(rawBody []byte, timestamp int64, receivedSigHex string) bool {
	expectedSigBytes, err := hex.DecodeString(receivedSigHex)
	if err != nil {
		return false
	}

	// Message: timestamp . raw_body
	macPayload := fmt.Sprintf("%d.", timestamp)
	message := append([]byte(macPayload), rawBody...)

	for _, secret := range wr.secrets {
		mac := hmac.New(sha256.New, []byte(secret))
		mac.Write(message)
		computedSig := mac.Sum(nil)

		// MANDATORY: Constant-time comparison via hmac.Equal
		if hmac.Equal(computedSig, expectedSigBytes) {
			return true
		}
	}
	return false
}

func parseSignatureHeader(header string) (int64, string, error) {
	var timestamp int64 = -1
	var sig string

	parts := strings.Split(header, ",")
	for _, part := range parts {
		kv := strings.SplitN(strings.TrimSpace(part), "=", 2)
		if len(kv) != 2 {
			continue
		}
		switch kv[0] {
		case "t":
			ts, err := strconv.ParseInt(kv[1], 10, 64)
			if err == nil {
				timestamp = ts
			}
		case "v1", "sha256":
			sig = kv[1]
		}
	}

	if timestamp == -1 || sig == "" {
		return 0, "", errors.New("missing timestamp or signature in header")
	}
	return timestamp, sig, nil
}
```

---

### 3.2 SQL / PostgreSQL: Inbound Deduplication & Outbound Outbox Schema

```sql
-- ============================================================================
-- 1. INBOUND WEBHOOK DEDUPLICATION & ASYNC PROCESSING TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS webhook_inbound_events (
    id              BIGSERIAL PRIMARY KEY,
    source          VARCHAR(64) NOT NULL,            -- e.g. 'stripe', 'github', 'shopify'
    event_id        VARCHAR(255) NOT NULL,           -- Provider's unique event identifier
    event_type      VARCHAR(128),                    -- e.g. 'payment_intent.succeeded'
    raw_payload     JSONB NOT NULL,                  -- Exact unmutated payload received
    status          VARCHAR(32) NOT NULL DEFAULT 'pending', -- 'pending', 'processing', 'completed', 'failed'
    attempt_count   INT NOT NULL DEFAULT 0,
    last_error      TEXT,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at    TIMESTAMPTZ,
    CONSTRAINT uq_webhook_inbound_source_event UNIQUE (source, event_id)
);

CREATE INDEX IF NOT EXISTS idx_webhook_inbound_pending
    ON webhook_inbound_events (received_at)
    WHERE status = 'pending';

-- ============================================================================
-- 2. OUTBOUND WEBHOOK TRANSACTIONAL OUTBOX TABLE
-- ============================================================================
CREATE TABLE IF NOT EXISTS webhook_outbound_deliveries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subscriber_id   VARCHAR(64) NOT NULL,            -- Target subscriber tenant/user ID
    target_url      TEXT NOT NULL,                   -- HTTPS endpoint of the subscriber
    event_type      VARCHAR(128) NOT NULL,           -- e.g. 'order.created'
    payload         JSONB NOT NULL,                  -- Canonical JSON payload
    secret_key_id   VARCHAR(64) NOT NULL,            -- Reference to subscriber's signing secret
    status          VARCHAR(32) NOT NULL DEFAULT 'pending', -- 'pending', 'delivering', 'delivered', 'failed', 'dlq'
    attempt_count   INT NOT NULL DEFAULT 0,
    max_attempts    INT NOT NULL DEFAULT 10,
    next_retry_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_status_code INT,
    last_error      TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_webhook_outbound_schedule
    ON webhook_outbound_deliveries (next_retry_at, status)
    WHERE status IN ('pending', 'failed');

-- Worker query: Lock-free concurrency with FOR UPDATE SKIP LOCKED
-- SELECT id, subscriber_id, target_url, payload, secret_key_id, attempt_count
-- FROM webhook_outbound_deliveries
-- WHERE status IN ('pending', 'failed')
--   AND next_retry_at <= NOW()
-- ORDER BY next_retry_at ASC
-- LIMIT 50
-- FOR UPDATE SKIP LOCKED;
```

---

## 4. Complete Production-Ready TypeScript Engine: `AgenticWebhookEngine`

Below is the complete, zero-dependency, production-grade TypeScript engine enforcing both inbound constant-time verification and outbound transactional delivery with decorrelated jitter.

```typescript
import * as crypto from 'node:crypto';

export interface InboundVerificationOptions {
  toleranceSeconds?: number; // Defaults to 300s (5 minutes)
  headerTimestampPrefix?: string; // e.g. 't'
  headerSignaturePrefix?: string; // e.g. 'v1'
}

export interface InboundVerificationResult {
  valid: boolean;
  timestamp: number;
  matchedSecretIndex: number;
  error?: string;
}

export interface OutboundSigningResult {
  timestamp: number;
  signature: string;
  header: string;
}

export interface OutboundDispatchAttempt {
  attempt: number;
  nextDelayMs: number;
  isTerminal: boolean;
}

/**
 * Production-Grade Agentic Webhook Engine enforcing constant-time HMAC validation,
 * zero-downtime dual-key rotation, raw-body preservation, and decorrelated jitter.
 */
export class AgenticWebhookEngine {
  private readonly defaultToleranceSec: number;

  constructor(toleranceSeconds: number = 300) {
    this.defaultToleranceSec = toleranceSeconds;
  }

  // ==========================================================================
  // 1. INBOUND VERIFICATION: Constant-Time & Dual-Key Resilient
  // ==========================================================================

  /**
   * Verifies an inbound webhook against one or more active secrets using constant-time comparison.
   * NEVER pass a JSON.stringify() string; always pass the raw Buffer captured from the HTTP stream.
   */
  public verifyInbound(
    rawBody: Buffer,
    signatureHeader: string,
    secrets: string[],
    options: InboundVerificationOptions = {}
  ): InboundVerificationResult {
    if (!Buffer.isBuffer(rawBody)) {
      return {
        valid: false,
        timestamp: 0,
        matchedSecretIndex: -1,
        error: 'Invariant Violation: rawBody MUST be an unmutated Node.js Buffer',
      };
    }

    if (!secrets || secrets.length === 0) {
      return {
        valid: false,
        timestamp: 0,
        matchedSecretIndex: -1,
        error: 'Configuration Error: No webhook signing secrets provided',
      };
    }

    const tolerance = options.toleranceSeconds ?? this.defaultToleranceSec;
    const tPrefix = options.headerTimestampPrefix ?? 't';
    const sPrefix = options.headerSignaturePrefix ?? 'v1';

    // Parse header: format "t=1614...,v1=abc..."
    const parsed = this.parseSignatureHeader(signatureHeader, tPrefix, sPrefix);
    if (!parsed) {
      return {
        valid: false,
        timestamp: 0,
        matchedSecretIndex: -1,
        error: 'Malformed signature header format',
      };
    }

    const { timestamp, receivedSignatureHex } = parsed;

    // Check temporal skew window (|t_wall - t_hook| <= tolerance)
    const nowSec = Math.floor(Date.now() / 1000);
    const skew = Math.abs(nowSec - timestamp);
    if (skew > tolerance) {
      return {
        valid: false,
        timestamp,
        matchedSecretIndex: -1,
        error: `Timestamp skew ${skew}s exceeds tolerance of ${tolerance}s`,
      };
    }

    let receivedSigBuffer: Buffer;
    try {
      receivedSigBuffer = Buffer.from(receivedSignatureHex, 'hex');
    } catch {
      return {
        valid: false,
        timestamp,
        matchedSecretIndex: -1,
        error: 'Invalid hexadecimal signature encoding',
      };
    }

    const messageToSign = Buffer.concat([
      Buffer.from(`${timestamp}.`, 'utf8'),
      rawBody,
    ]);

    // Iterate through all active candidate secrets (supports zero-downtime rotation)
    for (let i = 0; i < secrets.length; i++) {
      const secret = secrets[i];
      const hmac = crypto.createHmac('sha256', secret);
      hmac.update(messageToSign);
      const computedSigBuffer = hmac.digest();

      // MANDATORY: Constant-time comparison via crypto.timingSafeEqual
      if (this.constantTimeEquals(receivedSigBuffer, computedSigBuffer)) {
        return {
          valid: true,
          timestamp,
          matchedSecretIndex: i,
        };
      }
    }

    return {
      valid: false,
      timestamp,
      matchedSecretIndex: -1,
      error: 'Signature mismatch across all active candidate secrets',
    };
  }

  // ==========================================================================
  // 2. OUTBOUND SIGNING: Standard Canonical HMAC-SHA256 Generation
  // ==========================================================================

  /**
   * Signs an outbound webhook payload with a cryptographic timestamp and HMAC-SHA256 digest.
   */
  public signPayload(
    payloadStringOrBuffer: string | Buffer,
    secret: string,
    explicitTimestampSec?: number
  ): OutboundSigningResult {
    const timestamp = explicitTimestampSec ?? Math.floor(Date.now() / 1000);
    const bodyBuf = Buffer.isBuffer(payloadStringOrBuffer)
      ? payloadStringOrBuffer
      : Buffer.from(payloadStringOrBuffer, 'utf8');

    const message = Buffer.concat([
      Buffer.from(`${timestamp}.`, 'utf8'),
      bodyBuf,
    ]);

    const hmac = crypto.createHmac('sha256', secret);
    hmac.update(message);
    const signature = hmac.digest('hex');

    return {
      timestamp,
      signature,
      header: `t=${timestamp},v1=${signature}`,
    };
  }

  // ==========================================================================
  // 3. RESILIENT RETRY SCHEDULING: Decorrelated Jitter Backoff
  // ==========================================================================

  /**
   * Calculates next retry delay with full decorrelated jitter to prevent thundering herds.
   */
  public calculateRetrySchedule(
    currentAttempt: number,
    previousDelayMs: number = 5000,
    maxAttempts: number = 10,
    maxDelayMs: number = 86400000 // 24 hours
  ): OutboundDispatchAttempt {
    if (currentAttempt >= maxAttempts) {
      return {
        attempt: currentAttempt,
        nextDelayMs: 0,
        isTerminal: true, // Transition to DLQ
      };
    }

    const baseDelayMs = 5000;
    // Decorrelated jitter: next = min(maxDelay, Uniform(baseDelay, prevDelay * 3))
    const sleepCeiling = previousDelayMs * 3;
    const randomRange = Math.max(0, sleepCeiling - baseDelayMs);
    const rawDelay = baseDelayMs + Math.random() * randomRange;
    const nextDelayMs = Math.floor(Math.min(maxDelayMs, rawDelay));

    return {
      attempt: currentAttempt + 1,
      nextDelayMs,
      isTerminal: false,
    };
  }

  // ==========================================================================
  // 4. PRIVATE CRYPTOGRAPHIC HELPERS
  // ==========================================================================

  private constantTimeEquals(a: Buffer, b: Buffer): boolean {
    if (a.length !== b.length) {
      return false;
    }
    return crypto.timingSafeEqual(a, b);
  }

  private parseSignatureHeader(
    header: string,
    tPrefix: string,
    sPrefix: string
  ): { timestamp: number; receivedSignatureHex: string } | null {
    if (!header) return null;

    let timestamp: number | null = null;
    let signature: string | null = null;

    const parts = header.split(',');
    for (const part of parts) {
      const [key, value] = part.trim().split('=');
      if (!key || !value) continue;

      if (key === tPrefix) {
        const parsed = parseInt(value, 10);
        if (!isNaN(parsed)) timestamp = parsed;
      } else if (key === sPrefix || key === 'sha256') {
        signature = value;
      }
    }

    if (timestamp === null || !signature) {
      return null;
    }

    return { timestamp, receivedSignatureHex: signature };
  }
}
```

---

## 5. The 6 Absolute Anti-Pattern Prohibitions

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE 6 ABSOLUTE WEBHOOK PROHIBITIONS                      │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. ❌ NEVER serialize in-memory JSON to compute or verify an HMAC           │
│    (JSON.stringify alters keys, whitespace, and Unicode. Always verify raw) │
│                                                                             │
│ 2. ❌ NEVER compare signatures with === or == string equality               │
│    (Timing side-channels allow byte-by-byte forgery. Use timingSafeEqual)   │
│                                                                             │
│ 3. ❌ NEVER execute synchronous heavy operations inside the HTTP handler   │
│    (Upstream provider 5s/10s timeout causes retry stampedes. Return 202 ACK)│
│                                                                             │
│ 4. ❌ NEVER dispatch outbound webhooks inside uncommitted database tx      │
│    (Rollbacks cause phantom external webhooks. Use Transactional Outbox)    │
│                                                                             │
│ 5. ❌ NEVER omit the timestamp header or tolerance skew validation         │
│    (|t_wall - t_hook| must be bounded by ≤ 300s to reject replay attacks)   │
│                                                                             │
│ 6. ❌ NEVER configure a single unrotatable static webhook secret            │
│    (Support candidate secret array {current, previous} for zero-downtime)   │
└─────────────────────────────────────────────────────────────────────────────┘
```

1. **NEVER compute or verify HMAC signatures using re-serialized JSON strings**:
   - Calling `JSON.stringify(req.body)` produces subtle variations in property ordering, spacing, floating-point literals, and Unicode escape sequences that fail verification against genuine payloads.
   - Always intercept the raw request stream before middleware parsing, caching the original `Buffer` in `req.rawBody` or reading `await request.arrayBuffer()`.
2. **NEVER use standard variable-time string comparisons (`===`) for signature validation**:
   - Standard equality checks return as soon as the first divergent character is detected. This micro-architectural timing leak allows remote adversaries to infer valid signature bytes through differential timing analysis.
   - Always use `crypto.timingSafeEqual` in Node.js, `crypto.subtle.timingSafeEqual` in browser/worker environments, or `hmac.Equal` in Go.
3. **NEVER perform synchronous processing, database mutations, or downstream API calls in the inbound webhook endpoint**:
   - Inbound webhook controllers must restrict execution strictly to: (1) parsing headers, (2) validating HMAC in constant time, (3) storing the raw payload into an idempotent inbox/ledger table, and (4) returning HTTP 202 Accepted.
   - Total latency must remain well under $100\text{ms}$. Heavy processing must be offloaded to asynchronous background job queues.
4. **NEVER emit outbound HTTP webhooks directly inside database transaction blocks**:
   - If the database transaction aborts or deadlocks after the HTTP call succeeds, external consumers receive a webhook for an event that does not exist in your database.
   - Outbound webhooks must be inserted into an `outbound_deliveries` table within the same transaction that updates domain state, and relayed out-of-band by a polling or CDC daemon.
5. **NEVER accept webhooks without enforcing bounded timestamp validation**:
   - Signatures without a verified `t=` timestamp header can be captured and replayed indefinitely.
   - Always verify that $|t_{\text{current}} - t_{\text{hook}}| \le 300\text{ seconds}$, and enforce a unique constraint on `(source, event_id)` to discard duplicates within the tolerance window.
6. **NEVER hardcode a single signing secret without zero-downtime rotation capabilities**:
   - Key rotation is a standard security compliance requirement. A system that accepts only one secret will drop all incoming webhooks during the propagation delay when secrets are renewed.
   - Accept an array or list of candidate keys (`WEBHOOK_SECRETS="sec_new,sec_old"`), validating against each candidate until a constant-time match is discovered.

---

## 6. Machine-Verifiable Definition of Done (DoD) Matrix

Before marking any agentic task involving webhooks as complete, verify that every gate passes:

| Gate | Category | Invariant Verification Criterion | Automated Validation Command |
| :--- | :--- | :--- | :--- |
| **Gate 1** | **Raw Body Integrity** | Inbound endpoint receives and verifies exact raw unparsed `Buffer` / `[]byte`; no `JSON.stringify()` in HMAC pipeline. | `rg -n "JSON\.stringify\(.*body" **/webhooks* && exit 1 \|\| echo "PASS"` |
| **Gate 2** | **Constant-Time Verification** | All signature comparisons use `crypto.timingSafeEqual` (TS/JS) or `hmac.Equal` (Go); zero occurrences of `===` or `!=`. | `rg -n "(sig|signature|hmac)\s*(===|!==|==|!=)" **/webhooks* && exit 1 \|\| echo "PASS"` |
| **Gate 3** | **Temporal Skew Sentinel** | Header timestamp parsed and verified against $|t_{\text{wall}} - t_{\text{hook}}| \le 300\text{s}$; rejects expired payloads. | Automated test with $t = t_{\text{now}} - 301\text{s}$ asserts HTTP 400 rejection |
| **Gate 4** | **Sub-100ms Ingestion ACK** | Inbound endpoint enqueues payload to database ledger and returns HTTP `200` or `202` within $<100\text{ms}$. | Benchmark test asserting endpoint response latency $P_{99} < 100\text{ms}$ |
| **Gate 5** | **Zero-Downtime Key Rotation** | Receiver verifies against multiple candidate secrets; succeeds if any active key matches. | Unit test verifying signature signed with secondary/retiring key returns valid |
| **Gate 6** | **Transactional Outbox Egress** | Outbound webhooks committed in same DB transaction as domain state; dispatch retries use decorrelated jitter with DLQ fallback. | Verify SQL schema contains `outbound_deliveries` and worker implements jittered backoff |
