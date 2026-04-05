# Demo Session Output

Captured from `python -m src.cli --demo` on 5 April 2026.

## Offline Mode (`--offline`)

```
══════════════════════════════════════════════════════════════
  Deep Research Agent (G3) — CLI Demo
══════════════════════════════════════════════════════════════

  Query: Compare the economic impact of AI regulation in the EU (AI Act) vs the US approach. What are the key differences in enforcement mechanisms, and how might they affect tech startups operating in both markets?
  Mode:  OFFLINE (mock data, no LLM calls)

──────────────────────────────────────────────────────────────
  Step 1: Query Decomposition (mock)
──────────────────────────────────────────────────────────────
  Generated 4 sub-questions:

    1. What are the key provisions of the EU AI Act?
    2. How does the US approach AI regulation at the federal level?
    3. What are the enforcement mechanisms and penalties in each approach?
    4. How do these regulatory frameworks affect tech startups?

──────────────────────────────────────────────────────────────
  Step 2: Research (mock — stored in ChromaDB)
──────────────────────────────────────────────────────────────

  [1/4] What are the key provisions of the EU AI Act?
       Stored: 42 tokens | Budget: 42 / 10,000

  [2/4] How does the US approach AI regulation at the federal level?
       Stored: 44 tokens | Budget: 86 / 10,000

  [3/4] What are the enforcement mechanisms and penalties in each approach?
       Stored: 47 tokens | Budget: 133 / 10,000

  [4/4] How do these regulatory frameworks affect tech startups?
       Stored: 43 tokens | Budget: 176 / 10,000

──────────────────────────────────────────────────────────────
  Step 3: Retrieval (vector similarity)
──────────────────────────────────────────────────────────────

  [Source 1] relevance=0.5821  tokens=47
       EU enforcement: fines up to 7% of global annual turnover or EUR 35M. National authorities supe...

  [Source 2] relevance=0.5564  tokens=43
       EU: higher compliance costs for startups building high-risk AI; regulatory sandboxes partially...

  [Source 3] relevance=0.5407  tokens=42
       The EU AI Act, adopted March 2024, classifies AI systems into four risk tiers: unacceptable (b...

  [Source 4] relevance=0.4833  tokens=44
       The US has no comprehensive federal AI law. Regulation is sector-specific: the FDA regulates A...

──────────────────────────────────────────────────────────────
  Budget Report
──────────────────────────────────────────────────────────────
  Tokens used:           176 / 10,000
  Tokens remaining:    9,824
  Sub-queries done:        4
  LLM calls:               0  (offline mode)
  Est. cost (USD):    $0.0000  (offline mode)

══════════════════════════════════════════════════════════════
  Done. Run without --offline to use the live LLM API.
══════════════════════════════════════════════════════════════
```

## Live Mode (with API key)

When running with `HKBU_API_KEY` set and web search enabled, the output is similar but:

1. **Decomposition** is performed by GPT-4.1 (typically produces 3–5 sub-questions).
2. **Research** uses DuckDuckGo for each sub-question, feeds results to the LLM, and stores summarised answers in ChromaDB.
3. **Synthesis** retrieves the most relevant stored summaries via vector similarity and produces a final cited report.
4. **Budget Report** shows real token counts and estimated USD cost (typically $0.03–0.05).

Example budget report from a live run:

```
──────────────────────────────────────────────────────────────
  Budget & Cost Report
──────────────────────────────────────────────────────────────
  Tokens used:         4,231 / 10,000
  Tokens remaining:    5,769
  Sub-queries done:        4
  LLM calls:               6
  Est. cost (USD):   $0.0312
  Wall time:            23.4s

══════════════════════════════════════════════════════════════
  Done.
══════════════════════════════════════════════════════════════
```
