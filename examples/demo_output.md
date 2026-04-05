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

### Step 3: Aggregate + Budget Check (Code)

```
context length: ~7,240 chars
approx tokens: ~1,810
budget: 1,810 / 10,000 (WITHIN BUDGET)
truncated: No
```

### Step 4: Synthesize (LLM)

Final cited answer produced using `[Source 1-4]` citations.

### Step 5: Format Report (Code)

## Expected Output

```markdown
## Research Report

The economic impact of AI regulation differs significantly between the EU and US...

**EU AI Act** [Source 1]: The EU adopted the AI Act in March 2024, establishing
a risk-based classification system with four tiers...

**US Approach** [Source 2]: The United States has not enacted comprehensive
federal AI legislation. Instead, regulation is sector-specific...

**Enforcement Differences** [Source 3]: The EU enforcement model includes fines
of up to 7% of global annual turnover or EUR 35 million...

**Impact on Startups** [Source 4]: For tech startups operating in both markets,
the regulatory asymmetry creates a "Brussels Effect"...

---

### Constraint & Budget Summary

| Metric | Value |
|---|---|
| Tokens used | ~1,810 / 10,000 |
| Tokens remaining | ~8,190 |
| Sub-queries completed | 4 / 5 |
| Per-subquery limit | 2,000 tokens |
| Truncated | No |
| Budget status | WITHIN BUDGET |

*Token counts are approximated (chars / 4) since the Dify sandbox does not
include tiktoken. See evaluation.md for trade-off analysis.*
```
