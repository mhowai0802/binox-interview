# Evaluation: Architecture Trade-Offs

## 1. Memory Strategy: Why Summarisation Cascade?

Three memory strategies were considered:

| Strategy | Description | Pros | Cons |
|---|---|---|---|
| **Pure RAG** | Store raw documents, retrieve by similarity | Simple; no information loss at storage time | Context window fills quickly; retrieval noise on large corpora |
| **Sliding Window** | Keep only the last N tokens of conversation | Easy to implement; constant memory | Loses early research; poor for multi-part questions |
| **Summarisation Cascade** *(chosen)* | Summarise each chunk at ingestion, store summaries in vector DB | Bounded memory per chunk; retains the *gist* of all research | Summarisation can lose nuance; adds LLM cost |

### Why Summarisation Cascade wins for this task

The G3 brief explicitly requires operating under memory constraints. A pure RAG approach would either exceed the context window or require aggressive top-k filtering that risks dropping relevant results. A sliding window discards early sub-question answers, which defeats the purpose of decomposition.

The summarisation cascade gives a **middle ground**: every sub-question's answer is compressed to a fixed token budget *before* storage, guaranteeing that the total stored context stays bounded. At synthesis time, vector similarity selects the most relevant summaries — so the final LLM call receives a curated, budget-compliant context window.

**Trade-off acknowledged**: summarisation is lossy. If a sub-question's answer contains a critical number buried in a long paragraph, the summary might omit it. Mitigation: the summarisation prompt instructs the LLM to "preserve all key facts, figures, and citations."

## 2. Token Budget vs. Answer Quality

We define two budget knobs:

- **Per-sub-query budget (default 2 000 tokens)**: limits how much detail each research step can retain.
- **Per-session budget (default 10 000 tokens)**: limits the total research effort.

### Empirical reasoning

| Budget Config | Expected Behaviour |
|---|---|
| Sub-query 500 / Session 3 000 | Very aggressive compression; answers are short and may miss nuance |
| Sub-query 2 000 / Session 10 000 | **Sweet spot** — enough room for 5 sub-questions × 2 000 tokens each |
| Sub-query 5 000 / Session 50 000 | Near-unconstrained; defeats the purpose of the constraint exercise |

The 2 000 / 10 000 default was chosen because:
1. It forces the summariser to actually compress (most raw LLM answers are 500–3 000 tokens).
2. It allows all 5 sub-questions to fit without exhaustion.
3. It keeps cost per session low (~$0.01–0.05 on GPT-4.1 pricing).

## 3. Web Search Integration: DuckDuckGo vs. Alternatives

| Search Provider | Pros | Cons |
|---|---|---|
| **DuckDuckGo** *(chosen)* | Free, no API key, good privacy | Rate-limited for automation; results are general-purpose |
| Tavily | Purpose-built for AI agents; structured results | Paid API ($); adds vendor dependency |
| SearXNG (self-hosted) | No rate limits; privacy-focused | Requires hosting a separate service |
| Google Custom Search | High-quality results | Paid API ($); complex setup |
| No web search (LLM-only) | Zero external dependencies | Stuck with training cutoff; can't answer about recent events |

### Why DuckDuckGo

For a prototype / take-home, DuckDuckGo offers the best trade-off: **zero cost, zero setup, real web data**. The `duckduckgo-search` Python package wraps the public API and returns structured results (title, body, URL) that we feed directly to the LLM as grounding context.

The search module is designed with graceful fallback — if DuckDuckGo is unavailable or the package isn't installed, the agent falls back to pure LLM knowledge. This means the system never breaks due to search failures.

**Trade-off acknowledged**: DuckDuckGo may rate-limit automated queries during heavy use. A production system would switch to Tavily or self-hosted SearXNG.

## 4. Cost Analysis

### Per-session cost breakdown

Assuming GPT-4.1 pricing via the HKBU API (input: $2/1M tokens, output: $8/1M tokens):

| Step | Input Tokens | Output Tokens | Estimated Cost |
|---|---|---|---|
| Decompose (1 call) | ~200 | ~150 | ~$0.002 |
| Research (5 calls) | ~1 500 × 5 | ~2 000 × 5 | ~$0.095 |
| Synthesize (1 call) | ~10 000 | ~1 500 | ~$0.032 |
| **Total** | **~17 700** | **~11 650** | **~$0.13** |

Note: research calls now include web search context (~300–500 extra input tokens per call), which slightly increases input cost but significantly improves answer quality.

### Cost tracking in practice

The `LLMClient` class tracks cumulative token usage across all calls in a session and estimates USD cost in real time. Every API response includes:

```json
{
  "llm_usage": {
    "llm_calls": 6,
    "total_input_tokens": 15234,
    "total_output_tokens": 8921,
    "estimated_cost_usd": 0.0319
  }
}
```

For comparison, a human analyst answering the same multi-part question might take 1–2 hours. At $50/hour, that's $50–100 vs. ~$0.05–0.13 — a **500–1 000× cost reduction** with seconds of latency.

## 5. Dify vs. Code-Only Orchestration

| Aspect | Dify | Pure Python (e.g. LangChain) |
|---|---|---|
| Visual editing | Yes — non-engineers can modify the flow | No |
| Reproducibility | DSL export/import | Code in git (arguably simpler) |
| Debugging | Built-in run history & node-level logs | Requires custom logging |
| Flexibility | Limited to supported node types | Unlimited |
| Vendor lock-in | Moderate (Dify-specific DSL) | Low |

Dify was chosen because the brief suggests it, and because the visual workflow makes the architecture immediately understandable to reviewers. The memory service is kept as a separate Python API precisely to avoid lock-in — it works with any HTTP-capable orchestrator.

Additionally, the `/pipeline` endpoint and CLI tool (`src/cli.py`) provide a **Dify-free path** to test the full pipeline, ensuring the project is usable even without Dify installed.

## 6. ChromaDB vs. Alternatives

| Vector Store | Why Considered | Why Chosen / Not |
|---|---|---|
| **ChromaDB** *(chosen)* | Embedded, zero-config, Python-native | Perfect for a prototype; no external service needed |
| Qdrant | Better production scalability | Overkill for a take-home; requires separate server |
| Simple JSON log | Minimal dependencies | No vector similarity search; retrieval would be keyword-only |
| Dify built-in KB | Integrated | Less control over token tracking; harder to export/test |

## 7. Design Decisions for Demonstrability

| Decision | Why |
|---|---|
| CLI tool (`src/cli.py`) | Reviewer can test the full pipeline in one command without setting up Dify |
| `--offline` mode | Demonstrates the pipeline flow without an API key |
| `/pipeline` endpoint | Full research flow in a single HTTP call — easy to test with `curl` |
| Structured logging | Every step logged with timestamps, making the research process transparent |
| Cost tracking in responses | Shows business awareness without requiring external monitoring |

## 8. Limitations

1. **DuckDuckGo rate limits**: automated queries may be throttled. A production system needs Tavily or SearXNG.
2. **Single-session memory**: the budget resets per session. Cross-session retrieval is supported by ChromaDB (data persists), but the budget counter does not carry over.
3. **Lossy summarisation**: aggressive compression may drop details. A "detail-preserve" mode could store both the summary and a pointer to the full text.
4. **Embedding quality**: ChromaDB's default all-MiniLM-L6-v2 embedding is general-purpose. Domain-specific embeddings (e.g. fine-tuned on regulatory text) would improve retrieval precision.
5. **No parallelism**: sub-questions are researched sequentially. Parallel execution would reduce latency for independent sub-questions.

## 9. What I Would Do With More Time

- **Tavily integration** for reliable, AI-optimised web search.
- **Importance scoring**: allocate more token budget to higher-priority sub-questions rather than splitting evenly.
- **Streaming synthesis** for better UX during long answers.
- **Web UI** on top of the pipeline API for demo purposes.
- **Integration tests** that mock the LLM API to verify the full pipeline without incurring API costs.
- **Cross-session memory** with configurable retention policies.
- **Parallel sub-query research** using `asyncio.gather()` for lower latency.
