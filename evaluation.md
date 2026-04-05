# Evaluation: Architecture Trade-Offs

## 1. Why Pure Dify (vs. Python Hybrid)?

Two architectures were considered:

| Approach | Description | Pros | Cons |
|---|---|---|---|
| **Python hybrid** | FastAPI memory service + Dify for orchestration | Full control; precise token counting with tiktoken; unit-testable | Two services to run; DSL format fragility; higher setup friction |
| **Pure Dify** *(chosen)* | All logic inside a single Dify workflow | One-file import; zero external dependencies; visual and editable | Limited to Dify node types; approximate token counting; no persistent vector store |

### Why Pure Dify wins for this task

The brief says *"Use tools like n8n/Dify for orchestration"* and the evaluation weights Documentation & Reproducibility at 25%. A self-contained Dify workflow maximises reproducibility: the reviewer imports one YAML file and has a working prototype in under 2 minutes.

The Python hybrid approach required running a FastAPI server alongside Dify, managing ChromaDB persistence, and debugging DSL format mismatches between Dify versions. The added complexity provided precise token counting and vector retrieval, but those benefits are marginal for a prototype.

**Trade-off acknowledged**: by moving to pure Dify, we lose exact token counting and persistent cross-session memory. We mitigate this by using character-based approximation and documenting the limitation clearly.

## 2. Memory Strategy: Summarisation via LLM Constraints

Without an external vector store, the "summarisation cascade" is implemented through LLM-level constraints:

| Layer | Mechanism |
|---|---|
| **Per-subquery budget** | `max_tokens=2000` on the Research LLM node — the model physically cannot produce more tokens |
| **Per-session budget** | Code node counts total characters across all research results, truncates if `chars / 4 > 10,000` |
| **Max sub-questions** | Decompose prompt instructs "at most 5"; Code node enforces `[:5]` |

This is a different strategy from the classical "store-then-retrieve" RAG approach. Instead of storing summaries in a vector DB and retrieving by similarity, we pass all research results directly through the workflow graph. The Aggregate Code node acts as the "memory gate" — it enforces the session budget by truncating the combined context before it reaches the Synthesize LLM.

### Comparison with vector-based approaches

| Strategy | Pros | Cons |
|---|---|---|
| **Vector RAG (ChromaDB)** | Similarity-based retrieval; scales to many documents | Requires external service; embedding quality varies |
| **Direct context passing** *(chosen)* | Zero infrastructure; deterministic; all results used | Context window limit; no cross-session memory |

For a take-home prototype with 3-5 sub-questions, direct context passing is sufficient. The entire research output (~5,000-10,000 tokens) fits within modern context windows. Vector retrieval would only become necessary with dozens of sub-questions or cross-session persistence.

## 3. Token Counting: Approximation vs. Exact

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

**Mitigation**: the budget report explicitly states "Token counts are approximated (chars / 4)" so the reviewer knows this is intentional.

## 4. Cost Analysis

Assuming GPT-4o-mini pricing ($0.15 / 1M input, $0.60 / 1M output):

| Step | Input Tokens | Output Tokens | Estimated Cost |
|---|---|---|---|
| Decompose (1 call) | ~200 | ~100 | ~$0.0001 |
| Research (5 calls) | ~200 x 5 | ~2,000 x 5 | ~$0.006 |
| Synthesize (1 call) | ~10,000 | ~2,000 | ~$0.003 |
| **Total** | **~11,200** | **~12,100** | **~$0.009** |

At less than $0.01 per research session, the agent is extremely cost-efficient. For comparison, using GPT-4.1 via the HKBU API (estimated $2/$8 per 1M tokens) would cost ~$0.12 per session — still far cheaper than manual research.

## 5. Dify Workflow Design Decisions

| Decision | Why |
|---|---|
| Workflow mode (not Agent/Chatflow) | Deterministic flow matches the decompose-research-synthesise pattern; easier to debug and reproduce |
| Code nodes for budget tracking | Dify's native nodes don't support custom constraint logic; Code nodes provide full Python flexibility |
| JSON array for decomposition | Structured output enables reliable iteration; fallback parser handles non-JSON LLM responses |
| Post-iteration budget enforcement | Dify iterations don't support conditional early stopping; enforcing after iteration is simpler and still effective |
| Separate Parse node | LLM output is raw text; a dedicated Code node isolates parsing logic and handles edge cases |

## 6. Limitations

1. **Approximate token counting**: `chars / 4` is ~5-10% off from tiktoken. Acceptable for a prototype but would need exact counting in production.
2. **No web search**: research uses LLM parametric knowledge only. Adding a Dify Tool node for Tavily/SearXNG would ground answers in real-time data.
3. **No persistent memory**: research results live only within the workflow run. A Dify Knowledge Base integration would enable cross-session retrieval.
4. **No early stopping**: if the budget is exhausted mid-iteration, remaining sub-questions still execute. Dify doesn't natively support conditional break within iterations.
5. **Model dependency**: the workflow requires the reviewer to configure a model provider. The SETUP_GUIDE provides step-by-step instructions.

## 7. What I Would Do With More Time

- **Web search tool**: add a Dify Tool node (Tavily or SearXNG) before the Research LLM so each sub-question is grounded in real-time web data.
- **Knowledge Base integration**: store research results in a Dify Knowledge Base for cross-session memory and similarity-based retrieval.
- **Conversation variables**: use Dify's Variable Assigner to track budget in real time and implement conditional early stopping within the iteration.
- **Agent mode**: switch from Workflow to Agent so the LLM can dynamically choose between web search, knowledge base retrieval, and direct answer.
- **Streaming output**: use Dify's chatflow mode with Answer nodes for real-time streaming of the research process.
- **Parallel research**: enable parallel iteration to reduce latency when sub-questions are independent.
