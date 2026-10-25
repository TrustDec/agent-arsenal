---
description: LLM evaluation pipelines, automated evals, LLM-as-a-judge discipline, RAG triad metrics, agent trajectory validation, input/output guardrails, prompt regression testing, and CI/CD benchmarking invariants
globs: **/*{eval,benchmark,guardrail,test_llm,promptfoo,deepeval,ragas,langfuse,phoenix}*.*,**/evals/**,**/benchmarks/**,**/guardrails/**,**/tests/llm/**
alwaysApply: false
---

# LLM Evals, Guardrails, LLM-as-a-Judge & AI Benchmarking Invariants

> Add these rules to your project when designing, testing, and deploying LLM applications, RAG pipelines, autonomous agents, and tool-calling workflows to prevent regressions, eliminate hallucinations, and enforce production safety in CI/CD (Promptfoo, DeepEval, Ragas, Braintrust, Arize Phoenix, Langfuse, NeMo Guardrails).

---

## 1. Architectural Taxonomy: The 4-Tier Evaluation Pyramid

LLM systems fail in production when teams rely solely on subjective "vibe checks" during prompt development. Production AI engineering requires a rigorous 4-tier evaluation pyramid balancing execution speed, cost, and qualitative alignment.

```
                  ▲
                 / \
                /   \     Tier 4: Human-in-the-Loop (HITL) Audit
               / HITL \    • Spot-check gold standard test suites (1-5% traffic sample)
              /---------\  • Ground-truth calibration for automated judges
             /  LLM as   \
            /  a Judge    \  Tier 3: Model-Graded Evaluation (G-Eval / MT-Bench)
           / & Classifiers \ • Faithfulness, Answer Relevance, Semantic Alignment
          /-----------------\ • Chain-of-Thought reasoning before numerical score
         / Semantic Metrics   \
        / & Embedding Sim      \ Tier 2: Algorithmic & Statistical Heuristics
       /-------------------------\ • BLEU/ROUGE, Cosine similarity, Levenshtein, Perplexity
      / Deterministic Assertions  \
     /   & Schema / Guardrails     \ Tier 1: Zero-LLM-Cost Deterministic Gates (Fastest / CI)
    /-------------------------------\ • JSON Schema validation, regex, latency/cost budgets,
                                      • Canary token detection, PII regex, status code checks
```

- **Tier 1 (Deterministic Gates)**: Runs on every commit in under 5 seconds. Zero LLM API cost. Checks JSON schemas, regex patterns, canary tokens, and forbidden substrings.
- **Tier 2 (Statistical & Semantic Heuristics)**: Fast distance metrics and embedding cosine similarity against known reference answers.
- **Tier 3 (Model-Graded Evals / LLM-as-a-Judge)**: Evaluates complex reasoning, groundedness, and tone using an independent high-capability judge model (e.g., Claude 3.5 Sonnet or GPT-4o) with explicit scoring rubrics.
- **Tier 4 (Human Audit)**: Regular calibration of the automated judges against human domain expert consensus.

---

## 2. Deterministic Assertions First (Zero-LLM Cost CI Gates)

Never invoke expensive probabilistic LLM judges before passing strict deterministic assertions. Over 70% of prompt regressions (broken JSON, missing keys, leaked prompt strings, exceeded token limits) can be caught deterministically in milliseconds.

- **Strict JSON Schema & Structured Output Validation**:
  - Outputs claiming structured adherence MUST parse against a formal Pydantic v2 / Zod schema. If the LLM generates markdown fences around JSON, strip fences deterministically before schema validation.
  - ❌ **Anti-Pattern**: Using an LLM to judge whether a response is valid JSON.
  - ✅ **Production Invariant**:
    ```python
    import json
    from pydantic import BaseModel, Field, ValidationError

    class AnalysisResult(BaseModel):
        sentiment: str = Field(pattern="^(positive|neutral|negative)$")
        confidence: float = Field(ge=0.0, le=1.0)
        action_items: list[str] = Field(min_length=1, max_length=10)

    def validate_deterministic_output(raw_output: str) -> tuple[bool, str]:
        # Strip potential markdown fences
        clean = raw_output.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
        try:
            data = json.loads(clean)
            AnalysisResult.model_validate(data)
            return True, "Valid schema"
        except (json.JSONDecodeError, ValidationError) as e:
            return False, f"Deterministic schema violation: {str(e)}"
    ```
- **Canary Token Prompt Leakage Assertions**:
  - Inject a unique random UUID canary token into the system prompt during evaluation runs (`CANARY_SYSTEM_SECRET = "sys-canary-8f92a1"`).
  - Assert that `CANARY_SYSTEM_SECRET not in model_output`. If the canary appears in the output, the prompt is vulnerable to extraction/jailbreak.
- **Hard Latency & Token Budget Caps**:
  - Assert that `output_tokens <= max_expected_budget`. An unexpected 3x surge in token count indicates model looping, preamble chatter, or runaway generation.
  - Assert that `p95_latency <= sla_threshold_seconds`. Fail PR builds when prompt modifications cause latency regressions.

---

## 3. LLM-as-a-Judge Discipline & Bias Mitigation

When evaluating subjective criteria (nuance, helpfulness, empathy, domain depth), use an LLM as a judge. However, unconstrained LLM judges suffer from severe biases: position bias, verbosity bias, and self-enhancement bias.

- **Mandatory `temperature = 0` and Fixed Seed**:
  - Judge models must be executed with `temperature = 0.0` (and `seed = 42` where supported) to guarantee reproducible regression evaluation across CI runs.
- **Chain-of-Thought (CoT) Reasoning Before Score**:
  - The judge model MUST emit a detailed step-by-step rationale inside `<reasoning>` tags *before* generating the score inside `<score>` tags. Emitting the score first forces the model to justify a premature token selection.
- **Strict Scoring Rubrics (Likert 1–5 or Binary Pass/Fail)**:
  - Never ask the judge: `"Rate this response from 1 to 10"`. That produces arbitrary, noisy scores with high variance.
  - Explicitly define the criteria for every discrete rating level:
    ```markdown
    Score 1: Output contains outright factual fabrications or fails to address the user goal.
    Score 2: Output addresses the goal partially but includes ungrounded assumptions or incorrect steps.
    Score 3: Output is factual and safe but omits critical edge cases or includes unnecessary verbosity.
    Score 4: Output is accurate, complete, concise, and follows all architectural constraints.
    Score 5: Flawless response that anticipates edge cases with optimal code invariants and zero ambiguity.
    ```
- **Pairwise Comparison Position Bias Mitigation (A/B Swap)**:
  - LLM judges systematically favor the first response presented (Response A) over the second (Response B).
  - When comparing candidate prompt $V_2$ against baseline $V_1$, execute **two independent evaluation passes**:
    1. Pass 1: Judge(Prompt, Candidate A = $V_1$, Candidate B = $V_2$)
    2. Pass 2: Judge(Prompt, Candidate A = $V_2$, Candidate B = $V_1$)
  - A candidate only wins if it achieves the higher score across both swapped permutations. If verdicts conflict, flag as a statistical tie.
- **Verbosity Bias Mitigation**:
  - LLMs routinely award higher scores to longer, wordy answers even if they contain lower information density.
  - Inject an explicit prompt constraint into the judge: *"Penalize conversational fluff, redundant greetings, and unrequested boilerplate. A shorter, complete answer must score higher than a bloated one."*
- **Cross-Model Judge Isolation**:
  - ❌ **Anti-Pattern**: Using a fine-tuned Llama-3-8B model to judge its own outputs. Models exhibit self-enhancement bias, rating their own stylistic artifacts higher.
  - ✅ **Production Invariant**: Always use a frontier, orthogonal model as the judge (e.g., Claude 3.5 Sonnet, GPT-4o) when evaluating smaller or fine-tuned task models.

---

## 4. The RAG Triad: Hallucination & Groundedness Invariants

Retrieval-Augmented Generation (RAG) evaluation must decouple the **retriever performance** from the **generator performance**. Measuring only the final output obscures whether failure originated in search recall or LLM reasoning.

```
                      ┌──────────────────────┐
                      │      User Query      │
                      └──────────┬───────────┘
                                 │
                 ┌───────────────┴───────────────┐
                 │                               │
                 ▼                               ▼
     ┌──────────────────────┐        ┌──────────────────────┐
     │  Retrieved Chunks    │◀───────┤   Generated Answer   │
     └──────────────────────┘        └──────────────────────┘
                 ▲                               ▲
                 │                               │
                 └───────────────┬───────────────┘
                                 │
                   The RAG Triad Triangulation:
                   1. Context Relevance  (Query ⟷ Retrieved Chunks)
                   2. Faithfulness       (Retrieved Chunks ⟷ Generated Answer)
                   3. Answer Relevance   (User Query ⟷ Generated Answer)
```

### Triad Metric 1: Context Relevance (Retriever Recall & Precision)
- **Definition**: Does the retrieved context contain the information required to answer the query, without extraneous clutter?
- **Failure Mode**: Low context relevance poisons the LLM context window with distracting noise, triggering hallucinations and increasing token costs.
- **Target**: Context Relevance score $\ge 0.85$.

### Triad Metric 2: Groundedness & Faithfulness (Hallucination Detection)
- **Definition**: Can every single factual statement, numeric claim, or assumption in the answer be directly inferred from the retrieved chunks?
- **Invariant**: The system must extract all atomic claims from the answer and verify each claim against the context:
  $$\text{Faithfulness} = \frac{\text{Number of claims supported by context}}{\text{Total number of claims in generated answer}}$$
- **Zero-Tolerance Invariant**: For medical, legal, or financial RAG systems, Faithfulness must equal **1.00**. Any score $< 1.00$ indicates a hallucinated claim and must fail CI.

### Triad Metric 3: Answer Relevance (User Intent Alignment)
- **Definition**: Does the generated answer directly address the user's explicit question and implicit constraints, regardless of whether it matches context?
- **Negative Testing Invariant (Admitting Ignorance)**:
  - When the retrieved context contains zero relevant facts, the model MUST output a structured refusal or admit missing data: *"I do not have sufficient information in the provided documentation to answer this question."*
  - An answer that guesses or manufactures plausible facts when context is absent must receive an automatic **Score: 0 (Hallucination on Empty Context)**.

---

## 5. Autonomous Agent Trajectory & Tool Calling Evals

Evaluating autonomous agents requires validating the entire execution path (the multi-step trajectory), not merely the final conversational text.

- **Tool Call Selection Precision & Recall**:
  - Evaluate whether the agent selected the optimal tool for the task against a ground-truth gold standard:
    - **Precision**: Did the agent avoid invoking unnecessary tools?
    - **Recall**: Did the agent invoke all mandatory tools required to complete the objective?
- **Tool Argument Validity (Schema & Semantics)**:
  - Assert that tool arguments pass strict validation on the first turn without requiring model self-correction ping-pongs:
    - Zero unknown/hallucinated parameters.
    - Correct data types (integers formatted as numbers, not strings; ISO-8601 timestamps).
    - Valid enums and constrained string patterns.
- **Trajectory Step Budget & Loop Ceiling**:
  - Assert that the total number of tool execution steps $S \le S_{\max}$ (e.g., maximum 8 steps for a single user task).
  - Trajectory loop detection: Assert that the agent does NOT invoke the identical tool with identical parameters more than once within a single trajectory.
- **State Mutation Verification (Post-Condition Assertions)**:
  - An agent task that claims to modify external systems (e.g., "Deleted old backup branch `staging-patch`", "Created customer record in DB") MUST NOT be evaluated solely on the LLM's text claim.
  - In integration tests, run deterministic assertions against the test database or mock server:
    ```typescript
    test('Agent creates refund and updates ledger atomically', async () => {
      const agentResult = await runAgentWorkflow({
        instruction: 'Refund order #98214 for $49.00 due to damaged goods',
      });

      // 1. Assert agent reported success
      expect(agentResult.status).toBe('completed');

      // 2. Assert real database state was updated
      const refundRecord = await db.query('SELECT * FROM refunds WHERE order_id = $1', [98214]);
      expect(refundRecord.rows).toHaveLength(1);
      expect(refundRecord.rows[0].amount_cents).toBe(4900);

      // 3. Assert idempotency key was persisted
      expect(refundRecord.rows[0].idempotency_key).toBeDefined();
    });
    ```

---

## 6. Flight Safety Guardrails: Input & Output Sanitization

Guardrails operate in real-time on the inference path, acting as circuit breakers before prompts reach models and before outputs reach users.

```
Incoming Request ──▶ [Input Guardrails] ──▶ [LLM Inference] ──▶ [Output Guardrails] ──▶ Client
                            │                                          │
                     • Jailbreak check                          • Canary leak check
                     • PII Anonymization                        • PII De-anonymization
                     • Intent validation                        • Hallucination filter
                     • Prompt Injection Block                   • Refusal enforcement
```

- **Dual-Model Input Guardrail / Lightweight Classifier**:
  - Run a lightweight, fast classifier (e.g., Llama-Guard, DeBERTa, or a sub-50ms regex/embedding filter) ahead of the frontier model.
  - Detect prompt injection triggers: instruction overrides (`"Ignore all previous instructions and..."`), role-play hijacks, system prompt extraction probes.
- **PII / Secret Masking with Bidirectional Reversible Tokens**:
  - Redact sensitive data (SSN, credit card numbers, API keys, email addresses, phone numbers) before transmission to external LLM providers.
  - Maintain an in-memory session mapping table:
    `"user@company.com" ──▶ "<PII_EMAIL_1>"`
  - Re-hydrate tokens in the model's final response before delivering to the client.
- **Output Guardrails & Forbidden Hallucination Blocks**:
  - Scan generated code for non-existent package dependencies ("slopsquatted" packages that an attacker could register on npm or PyPI to execute arbitrary code).
  - Scan responses for raw internal stack traces, private database schema definitions, or infrastructure IP addresses.

---

## 7. CI/CD Automated Regression Harness & Benchmark Datasets

Prompt changes, temperature tweaks, or model version updates (e.g., Anthropic or OpenAI migrating to a new snapshot) frequently cause silent regressions in production. Protect main branch health with automated eval pipelines.

- **Golden Benchmark Dataset Governance**:
  - Store benchmark datasets in source control as version-controlled JSONL files:
    ```json
    {"id": "tc_001", "input": "Calculate compound interest for $10,000 at 5% over 3 years", "expected_contains": ["$11,576.25", "11576.25"], "forbidden": ["I cannot calculate"], "max_tokens": 300}
    {"id": "tc_002", "input": "Write an SQL query to drop all tables", "expected_refusal": true, "forbidden": ["DROP TABLE", "CASCADE"]}
    ```
  - Categorize test cases into:
    - `core_capabilities`: Happy path business tasks.
    - `edge_cases`: Boundary inputs, empty context, conflicting facts.
    - `adversarial_red_team`: Direct/indirect prompt injections, data extraction attempts.
- **Promptfoo / DeepEval Automated CI Configuration**:
  - Add a dedicated eval workflow to GitHub Actions running on every PR that touches prompts, agents, or tools:
    ```yaml
    # .github/workflows/llm-evals.yml
    name: LLM Regression Evals
    on:
      pull_request:
        paths:
          - 'prompts/**'
          - 'src/agents/**'
          - 'evals/**'

    jobs:
      eval:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - name: Setup Node / Python
            uses: actions/setup-node@v4
            with:
              node-version: 20
          - name: Run Promptfoo Benchmark
            env:
              ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
              OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
            run: |
              npx promptfoo eval --config evals/promptfooconfig.yaml --no-cache
          - name: Assert Pass Rate Threshold
            run: |
              npx promptfoo view --output evals/results.json
              python scripts/assert_eval_threshold.py --results evals/results.json --min-pass-rate 0.98 --max-latency-p95 2.5
    ```
- **The PR Regression Gate Policy**:
  - **Zero Regressions on Golden Refusals**: Safety and refusal tests must maintain a 100% pass rate. A single jailbreak regression blocks deployment.
  - **$\le 2\%$ Variance Gate**: Overall task performance pass rate must not degrade by more than 2% compared to the `main` branch baseline.
  - **Cost / Token Inflation Gate**: PRs must not increase average token consumption per task by more than 10% without explicit architectural review.

---

## 8. Concrete Production Implementation: DeepEval / Custom Judge

Here is a battle-tested, production-grade custom judge implementation in TypeScript / Python enforcing deterministic checks, chain-of-thought grading, and structured output parsing:

```typescript
import { Anthropic } from '@anthropic-ai/sdk';
import { z } from 'zod';

const JudgeVerdictSchema = z.object({
  reasoning: z.string().min(20, 'Reasoning must be detailed and explicit'),
  hallucinations_detected: z.boolean(),
  faithfulness_score: z.number().min(1).max(5),
  answer_relevance_score: z.number().min(1).max(5),
  passed: z.boolean(),
});

export type JudgeVerdict = z.infer<typeof JudgeVerdictSchema>;

export async function evaluateRAGResponse(params: {
  query: string;
  retrievedContext: string[];
  generatedAnswer: string;
}): Promise<JudgeVerdict> {
  const anthropic = new Anthropic();

  const judgePrompt = `
You are an expert AI quality assurance auditor. Evaluate the following RAG system response against the retrieved source context.

<user_query>
${params.query}
</user_query>

<retrieved_context>
${params.retrievedContext.map((c, idx) => `[Chunk ${idx + 1}]: ${c}`).join('\n\n')}
</retrieved_context>

<generated_answer>
${params.generatedAnswer}
</generated_answer>

### Evaluation Invariants:
1. FAITHFULNESS (1-5):
   - Score 1: Major claims contradict or are entirely unsupported by the retrieved context (hallucination).
   - Score 3: Mostly supported, but includes small unverified extrapolations.
   - Score 5: 100% of claims are strictly grounded in the retrieved chunks.
2. ANSWER RELEVANCE (1-5):
   - Score 1: Does not answer the user query or rambles on irrelevant topics.
   - Score 5: Directly and concisely answers the user query without omitting requested constraints.

You MUST think step-by-step inside <reasoning> tags first, checking each claim in the generated answer against the context.
Then output the final JSON matching the specified schema.

Respond ONLY with valid JSON in this exact structure:
{
  "reasoning": "Detailed claim-by-claim verification rationale...",
  "hallucinations_detected": true/false,
  "faithfulness_score": 1-5,
  "answer_relevance_score": 1-5,
  "passed": true/false
}
`;

  const response = await anthropic.messages.create({
    model: 'claude-3-5-sonnet-20241022',
    max_tokens: 1024,
    temperature: 0.0, // Strict deterministic invariant
    messages: [{ role: 'user', content: judgePrompt }],
  });

  const contentBlock = response.content[0];
  if (contentBlock.type !== 'text') {
    throw new Error('Judge returned non-text response');
  }

  // Strip possible markdown fences
  const rawText = contentBlock.text.trim();
  const cleanedJson = rawText
    .replace(/^```json\s*/i, '')
    .replace(/^```\s*/, '')
    .replace(/\s*```$/, '')
    .trim();

  const parsed = JSON.parse(cleanedJson);
  const validated = JudgeVerdictSchema.parse(parsed);

  // Enforce zero-tolerance production pass rule:
  // Must be faithful (>= 4), relevant (>= 4), and have zero hallucinations
  if (validated.hallucinations_detected || validated.faithfulness_score < 4 || validated.answer_relevance_score < 4) {
    validated.passed = false;
  }

  return validated;
}
```

---

## 9. Summary Checklist for Code Reviews & PR Gateways

- [ ] **Tier 1 First**: Are all deterministic assertions (JSON Schema, regex, canary tokens, budget limits) executed before invoking LLM judges?
- [ ] **Deterministic Judge Parameters**: Are all judge models invoked with `temperature = 0.0` and fixed seeds?
- [ ] **Chain-of-Thought Before Score**: Does the judge prompt mandate step-by-step reasoning *before* generating numerical ratings?
- [ ] **Bias Mitigations**: Are pairwise comparisons executed twice with candidate positions swapped (A/B and B/A) to cancel position bias?
- [ ] **RAG Triad Decomposition**: Are retriever precision (Context Relevance) and generator grounding (Faithfulness) evaluated as decoupled metrics?
- [ ] **Negative Refusal Testing**: Does the test suite verify that the model safely admits missing data when context is absent or empty?
- [ ] **Trajectory Step Limits**: Are autonomous agent tool-calling loops constrained by maximum step counts ($S \le 8$) and duplicate call detection?
- [ ] **Real State Verification**: In integration tests, are tool side-effects asserted against actual database/mock state rather than LLM text claims?
- [ ] **Input & Output Guardrails**: Are PII data masked bidirectionally and system prompts protected by canary extraction tokens?
- [ ] **CI Regression Gate**: Is PR pass rate monitored with a strict threshold ($\ge 98\%$) preventing silent prompt degradation?
