# Demo Session Output

Example output from the Dify workflow when given the demo query.

## Input

**Query:**
> Compare the economic impact of AI regulation in the EU (AI Act) vs the US approach. What are the key differences in enforcement mechanisms, and how might they affect tech startups operating in both markets?

## Workflow Trace

### Step 1: Decompose Query (LLM)

Generated 4 sub-questions:

```json
[
  "What are the key provisions and risk classification tiers of the EU AI Act?",
  "How does the United States approach AI regulation at the federal and state level?",
  "What are the enforcement mechanisms and penalties under each regulatory framework?",
  "How do these regulatory approaches affect tech startups operating in both the EU and US markets?"
]
```

### Step 2: Research Each Sub-Question (Iteration x4)

Each sub-question answered by the LLM with `max_tokens=2000`:

- **Sub-Q 1**: EU AI Act provisions, risk tiers, conformity assessments (~450 tokens)
- **Sub-Q 2**: US sector-specific approach, EO 14110, FTC role (~480 tokens)
- **Sub-Q 3**: EU fines (7% turnover), US enforcement via existing agencies (~420 tokens)
- **Sub-Q 4**: Compliance costs, regulatory sandboxes, Brussels Effect (~460 tokens)

### Step 3: Knowledge Base Retrieval

Query searched against the vector KB. Retrieved 3 chunks by cosine similarity:

- **KB: eu_ai_act_overview.txt** (score: 0.87) — Risk tiers, EUR 35M/7% penalties, regulatory sandbox provisions
- **KB: us_ai_policy.txt** (score: 0.82) — EO 14110, NIST AI RMF, state-level legislation breakdown
- **KB: ai_startup_impact.txt** (score: 0.79) — Compliance cost estimates, Brussels Effect, VC funding data ($67B US vs ~$12B EU)

### Step 4: Aggregate + Budget Check (Code)

```
research context: ~7,240 chars (4 sub-questions)
KB context: ~3,800 chars (3 chunks)
total context: ~11,040 chars
approx tokens: ~2,760
budget: 2,760 / 10,000 (WITHIN BUDGET)
truncated: No
```

### Step 5: Synthesize (LLM)

Final cited answer produced using `[Source 1-4]` for LLM research and `[KB: title]` for KB chunks.

### Step 6: Format Report (Code)

## Expected Output

```markdown
## Research Report

The economic impact of AI regulation differs significantly between the EU and US...

**EU AI Act** [Source 1]: The EU adopted the AI Act in March 2024, establishing
a risk-based classification system with four tiers. According to the EU AI Act
overview [KB: eu_ai_act_overview.txt], compliance costs for a single high-risk
AI system are estimated at EUR 200,000-400,000...

**US Approach** [Source 2]: The United States has not enacted comprehensive
federal AI legislation. Instead, regulation is sector-specific. As detailed
in [KB: us_ai_policy.txt], Executive Order 14110 was rescinded in January 2025,
creating regulatory uncertainty...

**Enforcement Differences** [Source 3]: The EU enforcement model includes fines
of up to 7% of global annual turnover or EUR 35 million [KB: eu_ai_act_overview.txt].
In contrast, the US relies on existing regulatory bodies like the FTC and FDA...

**Impact on Startups** [Source 4]: For tech startups operating in both markets,
the regulatory asymmetry creates a "Brussels Effect" [KB: ai_startup_impact.txt].
US AI startups receive approximately 5x more VC funding than EU counterparts
($67B vs ~$12B in 2024)...

---

### Constraint & Budget Summary

| Metric | Value |
|---|---|
| Tokens used | ~2,760 / 10,000 |
| Tokens remaining | ~7,240 |
| Sub-queries completed | 4 / 5 |
| KB documents retrieved | 3 |
| Per-subquery limit | 2,000 tokens |
| Truncated | No |
| Budget status | WITHIN BUDGET |

*Token counts are approximated (chars / 4). KB retrieval uses vector similarity
search with cosine distance. See evaluation.md for trade-off analysis.*
```
