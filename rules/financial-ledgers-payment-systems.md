---
description: Financial ledgers, double-entry bookkeeping, Stripe/Adyen payment systems, idempotency, atomic balance mutations, webhook verification, and PCI-DSS compliance invariants
globs: **/*{payment,billing,ledger,checkout,stripe,adyen,wallet,invoice,subscription,fintech,transaction}*.*,**/payments/**,**/ledgers/**,**/billing/**
alwaysApply: false
---

# Financial Ledgers, Payment Systems & Double-Entry Invariants

> Add these rules to your project when architecting, implementing, or auditing payment gateways, billing pipelines, wallet balance ledgers, checkout flows, or double-entry bookkeeping systems (Stripe, Adyen, PayPal, Ledger databases, PostgreSQL).

---

## 1. Minor Currency Units & The Absolute Ban on Floating-Point Money
Floating-point arithmetic (`IEEE 754 float32/float64`) cannot accurately represent decimal fractions:
$$0.1 + 0.2 = 0.30000000000000004$$
In financial systems, binary floating-point rounding errors accumulate across thousands of transactions, producing balance discrepancies, off-by-one-cent accounting audit failures, and legal liabilities.

- ❌ **THE FLOAT / DOUBLE ARITHMETIC CORRUPTION TRAP**:
  - Never store money in `FLOAT`, `DOUBLE`, `REAL`, or JavaScript `number` (IEEE 754 double precision).
  - Never execute arithmetic operations like taxes, discounts, or fee splits using standard language float operators (`price * 0.0825`).
- ✅ **The ISO 4217 Minor Currency Unit Invariant**:
  - Always represent, store, and transmit monetary amounts as **signed 64-bit integers (`BIGINT` / `int64`) in the currency's smallest minor unit** (cents, pence, yen):
    - USD, EUR, GBP (2 decimal places): `$10.50` $\to$ `1050`
    - JPY, KRW, VND, CLP (0 decimal places): `¥1050` $\to$ `1050`
    - BHD, KWD, OMR, JOD (3 decimal places): `10.500 KWD` $\to$ `10500`
- ✅ **The Arbitrary-Precision Decimal Rule (FX & Rates)**:
  - For exchange rates (FX), interest calculations, VAT/tax percentages, and fractional share allocations, use arbitrary-precision decimal types:
    - **PostgreSQL**: `NUMERIC(20, 8)` or `DECIMAL(20, 8)`.
    - **Go**: `github.com/shopspring/decimal`.
    - **TypeScript / Node**: `dinero.js` or `decimal.js`.
    - **Python**: `decimal.Decimal` (never pass floats to constructor: `Decimal('10.50')`, NOT `Decimal(10.50)`).
- ✅ **Banker's Rounding (Round Half to Even, IEEE 754)**:
  - Avoid naive "Round Half Up" when distributing fees or rounding fractional pennies, as it introduces an upward statistical accumulation bias. Use **Banker's Rounding** (round half to the nearest even integer) to maintain unbiased convergence across millions of transactions:
    ```go
    import "github.com/shopspring/decimal"

    // Banker's rounding to 0 decimal places (minor units):
    func RoundToMinorUnit(amount decimal.Decimal) int64 {
        return amount.RoundBank(0).IntPart()
    }
    ```

---

## 2. Double-Entry Bookkeeping & The Zero-Sum Invariant
Single-entry balance models (`UPDATE accounts SET balance = balance + 100`) are strictly forbidden in production financial systems because they erase transaction history, hide embezzlement or logic bugs, and make auditing mathematically impossible.

- ✅ **The Fundamental Accounting Equation**:
  $$\text{Assets} + \text{Expenses} = \text{Liabilities} + \text{Equity} + \text{Revenue}$$
  In formal balance terms:
  $$\sum \text{Debits} - \sum \text{Credits} = 0$$
- ✅ **The Multi-Posting Zero-Sum Constraint**:
  - Every financial event MUST generate an immutable **Journal Entry** containing at least two **Postings** (Legs).
  - The sum of all debits must strictly equal the sum of all credits within the same database transaction. Enforce this via a deferred transaction constraint:
    ```sql
    CREATE TABLE journal_entries (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        idempotency_key VARCHAR(128) UNIQUE NOT NULL,
        description TEXT NOT NULL,
        posted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    );

    CREATE TABLE ledger_postings (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        journal_entry_id UUID NOT NULL REFERENCES journal_entries(id) ON DELETE RESTRICT,
        account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
        amount BIGINT NOT NULL, -- Positive for Debit, Negative for Credit (or explicit direction column)
        currency VARCHAR(3) NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
    );

    -- Zero-sum verification trigger per journal entry:
    CREATE OR REPLACE FUNCTION verify_journal_entry_zero_sum()
    RETURNS TRIGGER AS $$
    DECLARE
        v_sum BIGINT;
    BEGIN
        SELECT COALESCE(SUM(amount), 0) INTO v_sum
        FROM ledger_postings
        WHERE journal_entry_id = NEW.journal_entry_id;

        IF v_sum <> 0 THEN
            RAISE EXCEPTION 'Double-entry violation: Journal entry % debits and credits do not balance (sum = %)',
                NEW.journal_entry_id, v_sum;
        END IF;
        RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE CONSTRAINT TRIGGER trg_verify_journal_balance
    AFTER INSERT OR UPDATE ON ledger_postings
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION verify_journal_entry_zero_sum();
    ```
- ❌ **ABSOLUTE BAN ON IN-PLACE MUTATION / DELETION**:
  - Never execute `UPDATE` or `DELETE` on `journal_entries` or `ledger_postings`.
  - Corrections must always be executed as new compensatory reversing journal entries (Credit Notes / Adjustment entries) preserving the full historical audit trail.

---

## 3. Concurrency Control: Preventing Balance Double-Spend & Deadlocks
In concurrent environments (e.g. flash sales, multi-threaded withdrawals, API retry storms), naive balance checks cause catastrophic double-spending:

- ❌ **THE NON-ATOMIC READ-MODIFY-WRITE DISASTER**:
  ```ts
  // ❌ FATAL RACE CONDITION: Two concurrent requests read balance = 100,
  // both approve 80 withdrawal, balance ends at -60!
  const account = await db.account.findUnique({ where: { id } });
  if (account.balance >= amount) {
    await db.account.update({
      where: { id },
      data: { balance: account.balance - amount },
    });
  }
  ```
- ✅ **Atomic Conditional Decrement with Guard Invariant**:
  - Execute balance deductions in a single atomic SQL statement with a non-negative guard condition:
    ```sql
    UPDATE accounts
    SET balance = balance - :debit_amount,
        updated_at = clock_timestamp()
    WHERE id = :account_id
      AND balance >= :debit_amount
    RETURNING balance;
    ```
  - If rows affected is `0`, immediately abort and return `402 Payment Required` or `422 Insufficient Funds`.
- ✅ **Deadlock-Free Deterministic Row Locking for Transfers**:
  - When transferring funds between two accounts ($A \to B$), locking account $A$ then account $B$ while a concurrent reverse transfer locks $B$ then $A$ triggers an instant database deadlock.
  - **The Deterministic Lock Ordering Invariant**: Always sort account UUIDs lexicographically before acquiring row-level locks (`SELECT ... FOR UPDATE`):
    ```go
    func TransferFunds(ctx context.Context, tx *sql.Tx, srcID, dstID uuid.UUID, amount int64) error {
        firstID, secondID := srcID, dstID
        if firstID.String() > secondID.String() {
            firstID, secondID = dstID, srcID
        }

        // Lock accounts in strictly identical deterministic order:
        query := `SELECT id, balance FROM accounts WHERE id IN ($1, $2) ORDER BY id ASC FOR UPDATE;`
        rows, err := tx.QueryContext(ctx, query, firstID, secondID)
        if err != nil {
            return fmt.Errorf("failed to acquire account locks: %w", err)
        }
        defer rows.Close()

        // Verify balance and apply postings...
        return nil
    }
    ```

---

## 4. Two-Phase Payment Lifecycles: Intent, Authorize & Capture
Immediate single-step charging (`capture=true` at checkout) leads to inventory mismatches and expensive refund merchant fees when backend order fulfillment fails.

- ✅ **The Authorize & Capture State Machine**:
  1. **Payment Intent Creation**: Persist the customer intent with deterministic `idempotency_key` and itemized order lines.
  2. **Authorization (Hold)**: Reserve funds on the customer's card without capturing. Holds typically expire after 7 days.
  3. **Fulfillment / Warehouse Allocation**: Verify physical inventory or provision digital access.
  4. **Capture (Settlement)**: Capture the authorized funds upon dispatch. If fulfillment fails, immediately execute a **Void / Authorization Release** (which carries zero cardholder interchange fee and does not subject the customer to statement refund wait times).
- ✅ **Payment Lifecycle States**:
  $$\text{Draft} \longrightarrow \text{RequiresPaymentMethod} \longrightarrow \text{RequiresAction (3DS)} \longrightarrow \text{Authorized} \longrightarrow \begin{cases} \text{Captured} \longrightarrow \text{Settled} \\ \text{Voided / Canceled} \\ \text{PartiallyRefunded} / \text{Refunded} \\ \text{Disputed / Chargeback} \end{cases}$$
- **Dispute & Chargeback Tracking Invariant**:
  - Maintain dedicated ledger postings for disputed amounts and chargeback fees ($15–$25 per dispute). Do not simply deduct the principal amount; preserve dispute evidence deadlines and stage funds in an escrow liability account.

---

## 5. Webhook Invariants: Raw Body HMAC, Constant-Time Compare & Replay Defense
Webhooks from payment processors (Stripe, Adyen, PayPal, Shopify) are asynchronous, out-of-order, and target public internet endpoints.

- ❌ **THE JSON-PARSED WEBHOOK VERIFICATION BUG**:
  - Parsing the HTTP request body with `express.json()` or body parser middleware before signature verification alters whitespace, key ordering, and unicode escaping, breaking HMAC-SHA256 signature verification.
- ✅ **Production Raw Buffer Invariant**:
  - Always capture the raw byte buffer (`Buffer` / `[]byte`) directly from the incoming stream:
    ```ts
    // Express configuration:
    app.post(
      '/webhooks/stripe',
      express.raw({ type: 'application/json' }),
      async (req, res) => {
        const sig = req.headers['stripe-signature'];
        const rawBody = req.body; // Untouched Buffer

        let event: Stripe.Event;
        try {
          event = stripe.webhooks.constructEvent(
            rawBody,
            sig!,
            process.env.STRIPE_WEBHOOK_SECRET!
          );
        } catch (err) {
          logger.warn({ err }, 'Invalid webhook signature');
          return res.status(400).send(`Webhook Error: ${(err as Error).message}`);
        }

        await processWebhookEvent(event);
        return res.status(200).json({ received: true });
      }
    );
    ```
- ✅ **Constant-Time Comparison & Timing Attack Elimination**:
  - When verifying custom webhook signatures (e.g. Adyen HMAC, PayPal webhook tokens), never use `===` or standard string equality (`if (sig === expected)`). Standard equality short-circuits on the first divergent character, leaking signature bytes via sub-microsecond timing side channels.
  - Always use `crypto.timingSafeEqual`:
    ```ts
    import crypto from 'node:crypto';

    function verifyHMAC(payload: Buffer, signatureHex: string, secret: string): boolean {
      const expectedHmac = crypto.createHmac('sha256', secret).update(payload).digest();
      const providedHmac = Buffer.from(signatureHex, 'hex');

      if (expectedHmac.length !== providedHmac.length) {
        return false;
      }
      return crypto.timingSafeEqual(expectedHmac, providedHmac);
    }
    ```
- ✅ **Replay Attack Defense & Timestamp Window**:
  - Extract the webhook timestamp header (e.g., `t=1710000000` in Stripe).
  - Reject any webhook where $|t_{\text{current}} - t_{\text{header}}| > 300\text{ seconds}$ (5 minutes) to prevent network replay attacks.

---

## 6. Pre-Persistence Discipline: The "Charge-Before-Write" Catastrophe
- ❌ **THE UNRECORDED CHARGE OUTAGE TRAP**:
  - Calling the payment gateway API (`stripe.paymentIntents.create(...)`) BEFORE recording the intent in the local database.
  - If the database query times out, crashes, or encounters a constraint violation immediately after the external API call succeeds, the customer's credit card is charged, but no record of the payment or order exists in your database.
- ✅ **The Pre-Persistence Invariant**:
  1. **Phase 1 (Pre-Persist Intent)**: Insert local `order` and `payment_record` with status `pending` inside a local database transaction.
  2. **Phase 2 (Gateway Mutation with Idempotency Key)**: Dispatch external gateway API request using a deterministically generated UUIDv5 or hash of the local `payment_record.id` as the gateway's `Idempotency-Key`.
  3. **Phase 3 (Post-Persist Gateway Result)**: Record external transaction ID (`ch_xxx`, `pi_xxx`) and advance state to `authorized` or `captured`.
  - If Phase 2 or Phase 3 crashes or times out, a background sweeper job queries the gateway using the deterministic idempotency key and reconciles the orphaned state cleanly.

---

## 7. Transactional Outbox for Financial Event Emission
Publishing event messages directly to Kafka/RabbitMQ inside an active database transaction risks phantom messages (events published before transaction commits, or events published even if the database transaction rolls back).

- ✅ **The Transactional Outbox Pattern**:
  - Write business ledger postings and outbox events in the **same atomic database transaction**:
    ```sql
    BEGIN;
    INSERT INTO journal_entries (...) VALUES (...);
    INSERT INTO ledger_postings (...) VALUES (...);

    -- Enqueue event in outbox table:
    INSERT INTO transactional_outbox (
        event_id,
        aggregate_type,
        aggregate_id,
        event_type,
        payload
    ) VALUES (
        gen_random_uuid(),
        'Payment',
        'pi_9823401823',
        'PaymentCaptured',
        '{"amount": 1050, "currency": "USD", "customer_id": "cust_123"}'::jsonb
    );
    COMMIT;
    ```
  - A separate, decoupled message relay (e.g., Debezium CDC or high-frequency polling worker) reads `transactional_outbox` and publishes events to Kafka with at-least-once delivery guarantees.
  - Downstream consumers enforce consumer idempotency via an `inbox` table tracking processed `event_id`s.

---

## 8. Daily Automated Reconciliation & Settlement (Three-Way Match)
Payment gateways and banks are external third-party systems. Bugs, chargebacks, network timeouts, and currency slippage inevitably cause divergences between internal ledger balances and actual money in the bank.

- ✅ **The Three-Way Match Reconciliation Engine**:
  Run an automated daily reconciliation batch matching three independent sources:
  1. **Internal Application Ledger**: Total captured payments, refunds, and adjustments recorded in `ledger_postings`.
  2. **Payment Gateway Settlement Report**: Daily Stripe Settlement CSV, Adyen Settlement Detail Report (SDR), or PayPal MT940 statement listing gross volume, interchange fees, gateway processing fees, and net payout.
  3. **Bank Statement Payout Records**: Actual wire/ACH deposits credited to corporate bank accounts.
- **Automated Discrepancy Alerting**:
  - Every transaction must match within a strict tolerance (zero tolerance for same-currency transactions).
  - Any unmatched transaction or fee variance $> 0.00$ must immediately raise a P1 incident ticket to the finance engineering team with exact transaction references.

---

## 9. PCI-DSS Scope Reduction & The Zero-PAN Invariant
Payment Card Industry Data Security Standard (PCI-DSS) imposes severe regulatory, auditing, and criminal liabilities on systems that store, process, or transmit raw cardholder data.

- ❌ **THE ZERO-PAN ABSOLUTE PROHIBITION**:
  - Never allow raw PAN (Primary Account Number / credit card number), CVV/CVC, or card PIN to touch your application backend servers, databases, redis caches, log files, or error reporting tools (Sentry/Datadog).
  - Never accept raw card inputs in standard backend REST API endpoints (`POST /api/checkout { card_number: "..." }`).
- ✅ **Client-Side Tokenization via Hosted Fields**:
  - All credit card inputs MUST be captured exclusively through iframe-isolated hosted components (Stripe Elements, Adyen Drop-in, Apple Pay, Google Pay).
  - The backend application server only receives a non-sensitive, single-use payment method token (e.g., `pm_1Oxxx`, `tok_1Oxxx`).
- ✅ **Permitted Card Metadata Invariant**:
  - Backend databases are strictly restricted to storing only non-PCI card metadata:
    - Masked last 4 digits (`last4`: `"4242"`).
    - Card brand / network (`brand`: `"visa" | "mastercard"`).
    - Expiration month/year (`exp_month: 12, exp_year: 2028`).
    - Cardholder name (optional).
- ✅ **PCI Log Redaction Filter**:
  - Implement regex sanitization middleware on all HTTP ingress and loggers to scrub any 13–19 digit number matching the Luhn algorithm before log records hit stdout/Datadog:
    ```go
    // Luhn algorithm verification pattern to scrub accidental card numbers in logs:
    var cardRegex = regexp.MustCompile(`\b(?:\d[ -]*?){13,19}\b`)

    func RedactSensitiveData(logMessage string) string {
        return cardRegex.ReplaceAllString(logMessage, "[REDACTED_CARD_NUMBER]")
    }
    ```
