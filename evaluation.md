# Evaluation: Architecture Trade-Offs

## 1. Why Pure Dify (vs. Python Hybrid)?

Two architectures were considered:

| Approach | Description | Pros | Cons |
|---|---|---|---|
| **Python hybrid** | FastAPI memory service + Dify for orchestration | Full control; precise token counting with tiktoken; unit-testable | Two services to run; DSL format fragility; higher setup friction |
| **Pure Dify** *(chosen)* | All logic inside a single Dify workflow | One-file import; zero external dependencies; visual and editable | Limited to Dify node types; approximate token counting |

### Why Pure Dify wins for this task

The brief says *"Use tools like n8n/Dify for orchestration"* and the evaluation weights Documentation & Reproducibility at 25%. A self-contained Dify workflow maximises reproducibility: the reviewer imports one YAML file and has a working prototype in under 5 minutes.

The Python hybrid approach required running a FastAPI server alongside Dify, managing ChromaDB persistence, and debugging DSL format mismatches between Dify versions. The added complexity provided precise token counting and vector retrieval, but those benefits are now achieved within Dify itself — vector retrieval through the built-in Knowledge Base, and approximate token counting through Code nodes.

## 2. Memory Architecture: Hybrid (LLM Research + Vector RAG)

The agent uses a two-source memory strategy:

### Source 1: LLM Parametric Research

Each sub-question is answered by an LLM within a `max_tokens=2000` budget. This leverages the model's parametric knowledge — the information encoded in its weights during training. The Dify iteration node processes sub-questions sequentially.

| Layer | Mechanism |
|---|---|
| **Per-subquery budget** | `max_tokens=2000` on the Research LLM node — the model physically cannot produce more tokens |
| **Max sub-questions** | Decompose prompt instructs "at most 5"; Code node enforces `[:5]` |

### Source 2: Vector Knowledge Base Retrieval (RAG)

After the research iteration, the original user query is searched against a Dify Knowledge Base using vector similarity (embedding + cosine distance). The top-K most relevant document chunks are retrieved.

| Layer | Mechanism |
|---|---|
| **Retrieval** | Dify's built-in Knowledge Base with embedding model (e.g., `text-embedding-3-small`) |
| **Top-K** | `top_k=3` on the Knowledge Base Retrieval node |
| **Score threshold** | `score_threshold=0.5` — only chunks with cosine similarity ≥ 0.5 are returned |
| **Budget integration** | KB chunks are counted in the same 10,000-token session budget as research results |

### Source Combination

The Aggregate Code node combines both sources into a single context block:
- Research results are labeled `[Source 1]`, `[Source 2]`, etc.
- KB retrieval results are labeled `[KB: document_title]`
- Both share the same 10,000-token session budget
- If total tokens exceed the budget, content is truncated (research results first, then KB chunks)

This hybrid approach provides:
- **Breadth** from LLM parametric knowledge (covers questions the KB docs don't address)
- **Depth** from vector retrieval (provides specific, factual, up-to-date information from curated documents)

### Comparison with alternative approaches

| Strategy | Pros | Cons |
|---|---|---|
| **Vector RAG only** | Grounded in specific documents; controllable | Limited by uploaded content; cold-start problem |
| **LLM research only** | Broad knowledge; no setup required | May hallucinate; no verifiable sources |
| **Hybrid (chosen)** | Best of both; KB provides ground truth, LLM fills gaps | Slightly more setup; KB requires document curation |
| **Episodic buffer** | Maintains conversation history | Overkill for single-session research |

For a take-home prototype, the hybrid approach demonstrates both the "memory strategy" and "retrieval of relevant context" requirements from the brief while remaining simple to set up.

## 3. Knowledge Base Design

### Document selection

The sample KB contains 3 documents specifically chosen to support the demo query about AI regulation:

| Document | Content | Why Included |
|---|---|---|
| `eu_ai_act_overview.txt` | EU AI Act provisions, risk tiers, penalties, timeline | Provides factual grounding for EU regulation questions |
| `us_ai_policy.txt` | US regulatory landscape, EO 14110, state laws, agency roles | Covers the US side of the comparison |
| `ai_startup_impact.txt` | Compliance costs, Brussels Effect, regulatory sandboxes, VC data | Directly addresses the startup impact aspect |

### Retrieval configuration

- **Top-K = 3**: retrieves the 3 most relevant chunks. With 3 documents, this ensures each document can contribute one chunk.
- **Score threshold = 0.5**: filters out low-relevance chunks. If the query is unrelated to AI regulation, fewer (or no) chunks are returned.
- **Reranking disabled**: keeps the setup simple and avoids requiring an additional reranking model.

### Scaling considerations

For a production deployment:
- Increase `top_k` as the KB grows (5-10 for 100+ documents)
- Enable reranking with a cross-encoder for better relevance ordering
- Use metadata filtering to scope retrieval by document type, date, or topic
- Add web search results to the KB for dynamic knowledge updates

## 4. Token Counting: Approximation vs. Exact

The Dify code sandbox (Python 3.14, sandboxed) does not include `tiktoken`. We use:

```python
approx_tokens = len(text) // 4
```

### How accurate is this?

| Method | "Hello, world!" | 500-word paragraph | Relative error |
|---|---|---|---|
| tiktoken (cl100k_base) | 4 tokens | ~670 tokens | — |
| `len(text) // 4` | 3 tokens | ~625 tokens | ~5-10% |
| `len(text.split())` | 2 tokens | ~500 tokens | ~25% |

The character-based heuristic (`chars / 4`) is the standard approximation used across the industry (OpenAI's own documentation suggests "1 token ~= 4 characters"). For budget enforcement purposes, a 5-10% error is acceptable — the constraints are self-defined and the purpose is to demonstrate the *concept* of bounded-memory research, not production-grade accounting.

**Mitigation**: the budget report explicitly states the approximation method so the reviewer knows this is intentional.

## 5. Cost Analysis

Assuming GPT-4o-mini pricing ($0.15 / 1M input, $0.60 / 1M output):

| Step | Input Tokens | Output Tokens | Estimated Cost |
|---|---|---|---|
| Decompose (1 call) | ~200 | ~100 | ~$0.0001 |
| Research (5 calls) | ~200 x 5 | ~2,000 x 5 | ~$0.006 |
| KB Retrieval | ~50 (embedding) | — | ~$0.00001 |
| Synthesize (1 call) | ~10,000 | ~2,000 | ~$0.003 |
| **Total** | **~11,250** | **~12,100** | **~$0.009** |

At less than $0.01 per research session, the agent is extremely cost-efficient. The KB retrieval adds negligible cost (embedding only). For comparison, using GPT-4.1 via the HKBU API (estimated $2/$8 per 1M tokens) would cost ~$0.12 per session — still far cheaper than manual research.

## 6. Dify Workflow Design Decisions

| Decision | Why |
|---|---|
| Workflow mode (not Agent/Chatflow) | Deterministic flow matches the decompose-research-retrieve-synthesise pattern; easier to debug and reproduce |
| Knowledge Base Retrieval node after iteration | Queries the KB with the original query (broader context) rather than per-sub-question (which would fragment retrieval) |
| `multiple` retrieval mode | Doesn't require a separate re-ranking model; simpler setup |
| Code nodes for budget tracking | Dify's native nodes don't support custom constraint logic; Code nodes provide full Python flexibility |
| JSON array for decomposition | Structured output enables reliable iteration; fallback parser handles non-JSON LLM responses |
| Post-iteration budget enforcement | Dify iterations don't support conditional early stopping; enforcing after iteration is simpler and still effective |
| Separate Parse node | LLM output is raw text; a dedicated Code node isolates parsing logic and handles edge cases |

## 7. Limitations

1. **Approximate token counting**: `chars / 4` is ~5-10% off from tiktoken. Acceptable for a prototype but would need exact counting in production.
2. **No web search**: research uses LLM parametric knowledge only. Adding a Dify Tool node for Tavily/SearXNG would ground answers in real-time data.
3. **KB requires manual setup**: the user must create a Knowledge Base, upload documents, and link it to the workflow. This is a one-time cost.
4. **Static KB content**: the sample documents are point-in-time snapshots. A production system would ingest updated content automatically.
5. **No early stopping**: if the budget is exhausted mid-iteration, remaining sub-questions still execute. Dify doesn't natively support conditional break within iterations.
6. **Model dependency**: the workflow requires the reviewer to configure a model provider. The SETUP_GUIDE provides step-by-step instructions.

## 8. Business Impact & Client Value

### The problem this solves

Research-intensive organisations — consulting firms, legal teams, investment analysts, regulatory compliance departments — spend significant time on multi-faceted research queries. A senior analyst might take 2-4 hours to decompose a complex question, gather sources, cross-reference findings, and synthesise a coherent report. This process is expensive, inconsistent across analysts, and doesn't scale.

### How the agent creates value

| Dimension | Manual Research | Research Agent | Improvement |
|---|---|---|---|
| **Time per query** | 2-4 hours | ~30 seconds | ~200-400x faster |
| **Cost per query** | $80-160 (analyst hourly rate) | $0.009-0.12 (API cost) | ~1,000x cheaper |
| **Consistency** | Varies by analyst, fatigue, time pressure | Deterministic workflow, same quality at query 1 and query 1,000 | Eliminates variance |
| **Scalability** | Linear headcount scaling | Same workflow handles 100+ queries/day | Near-zero marginal cost |
| **Audit trail** | Notes, emails, scattered docs | Structured report with source citations and budget summary | Built-in compliance |

### Target use cases

1. **Regulatory compliance monitoring** — a fintech startup needs to understand how new AI regulations in multiple jurisdictions affect their product. The agent decomposes the question, retrieves relevant regulatory documents from the KB, and produces a cited comparison report in seconds.
2. **Due diligence research** — an investment team evaluating an AI startup needs to assess regulatory risk across markets. Instead of assigning a junior analyst for half a day, they run the agent and get a structured first-pass analysis.
3. **Competitive intelligence** — a product team wants to understand how competitors are responding to new regulations. The agent handles the multi-part decomposition while the team focuses on strategic decisions.
4. **Client deliverables** — a consulting firm can use the agent as a first-draft generator for research sections of client reports, reducing turnaround time from days to hours.

### ROI calculation

For a consulting firm running 20 research queries per week:

| Item | Manual | Agent-assisted |
|---|---|---|
| Queries/week | 20 | 20 |
| Time per query | 3 hours | 15 min (review + edit) |
| Analyst cost | $100/hr | $100/hr |
| API cost per query | — | $0.12 |
| **Weekly cost** | **$6,000** | **$502.40** |
| **Monthly savings** | — | **~$22,000** |

Even accounting for setup time, KB curation, and the need for human review of outputs, the agent pays for itself within the first week of deployment.

### Why the constraint-aware design matters for clients

The self-imposed budget constraints (10K tokens/session, 2K/sub-query) aren't just a technical exercise — they directly address client concerns:

- **Predictable costs**: clients can budget for AI usage because each query has a known maximum cost
- **Explainable outputs**: the budget summary table in every report shows exactly what the agent did and how much it consumed
- **Governance-ready**: the constraint enforcement mechanism provides the kind of guardrails that enterprise compliance teams require before approving AI tools for production use

## 9. What I Would Do With More Time

- **Web search tool**: add a Dify Tool node (Tavily or SearXNG) before the Research LLM so each sub-question is grounded in real-time web data.
- **Conversation variables**: use Dify's Variable Assigner to track budget in real time and implement conditional early stopping within the iteration.
- **Agent mode**: switch from Workflow to Agent so the LLM can dynamically choose between web search, knowledge base retrieval, and direct answer.
- **Streaming output**: use Dify's chatflow mode with Answer nodes for real-time streaming of the research process.
- **Parallel research**: enable parallel iteration to reduce latency when sub-questions are independent.
- **Auto-ingest**: periodically scrape relevant sources and ingest into the KB for up-to-date information.
