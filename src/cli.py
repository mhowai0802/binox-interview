"""CLI demonstration of the full research pipeline.

Usage
-----
    python -m src.cli "Your complex research question here"
    python -m src.cli --demo          # run with the built-in demo question
    python -m src.cli --offline       # run without LLM API (mock data)
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import os
import tempfile

def _suppress_noisy_loggers() -> None:
    """Silence verbose third-party loggers for a clean CLI output."""
    import logging
    os.environ["ANONYMIZED_TELEMETRY"] = "False"
    for name in ("httpx", "chromadb", "httpcore", "urllib3", "src.main",
                 "chromadb.telemetry", "chromadb.telemetry.product.posthog"):
        logging.getLogger(name).setLevel(logging.CRITICAL)


DEMO_QUERY = (
    "Compare the economic impact of AI regulation in the EU (AI Act) "
    "vs the US approach. What are the key differences in enforcement "
    "mechanisms, and how might they affect tech startups operating in "
    "both markets?"
)

SEPARATOR = "─" * 62
DOUBLE_SEP = "═" * 62


def _print_header() -> None:
    print()
    print(DOUBLE_SEP)
    print("  Deep Research Agent (G3) — CLI Demo")
    print(DOUBLE_SEP)
    print()


def _print_section(title: str) -> None:
    print(f"\n{SEPARATOR}")
    print(f"  {title}")
    print(SEPARATOR)


def _run_live(query: str) -> None:
    """Run the full pipeline against the real LLM API."""
    _suppress_noisy_loggers()
    os.environ.setdefault("CHROMA_PERSIST_DIR", tempfile.mkdtemp())

    from fastapi.testclient import TestClient
    from src.main import app

    _print_header()
    print(f"  Query: {query}\n")

    t0 = time.time()

    with TestClient(app) as client:
        # Step 1 — Reset
        client.post("/memory/reset")

        # Step 2 — Decompose
        _print_section("Step 1: Query Decomposition")
        resp = client.post("/decompose", json={"query": query})
        if resp.status_code != 200:
            print(f"  ERROR: {resp.status_code} — {resp.text}")
            return
        decomposition = resp.json()
        subquestions = decomposition["subquestions"]
        print(f"  Generated {len(subquestions)} sub-questions:\n")
        for i, sq in enumerate(subquestions, 1):
            print(f"    {i}. {sq}")

        # Step 3 — Research each sub-question
        _print_section("Step 2: Research (with web search + LLM)")
        for i, sq in enumerate(subquestions, 1):
            budget = client.get("/memory/budget").json()
            print(f"\n  [{i}/{len(subquestions)}] {sq}")
            print(f"       Budget: {budget['tokens_used']:,} / {budget['max_per_session']:,} tokens")

            resp = client.post("/research", json={
                "subquery": sq,
                "session_id": "cli-demo",
            })
            if resp.status_code != 200:
                print(f"       ERROR: {resp.status_code}")
                continue

            result = resp.json()
            if result.get("status") == "skipped":
                print(f"       SKIPPED — {result['reason']}")
                break

            web_count = result.get("web_sources", 0)
            tokens = result.get("tokens", 0)
            print(f"       Web sources: {web_count} | Stored: {tokens:,} tokens")

        # Step 4 — Synthesise
        _print_section("Step 3: Synthesis")
        resp = client.post("/synthesize", json={
            "query": query,
            "top_k": 10,
            "session_id": "cli-demo",
        })
        if resp.status_code != 200:
            print(f"  ERROR: {resp.status_code}")
            return

        synthesis = resp.json()
        print()
        print(synthesis["answer"])

        # Step 5 — Budget report
        _print_section("Budget & Cost Report")
        budget = synthesis.get("budget", {})
        llm_usage = synthesis.get("llm_usage", {})
        elapsed = time.time() - t0
        print(f"  Tokens used:       {budget.get('tokens_used', '?'):>8,} / {budget.get('max_per_session', '?'):,}")
        print(f"  Tokens remaining:  {budget.get('tokens_remaining', '?'):>8,}")
        print(f"  Sub-queries done:  {budget.get('subquery_count', '?'):>8}")
        print(f"  LLM calls:         {llm_usage.get('llm_calls', '?'):>8}")
        print(f"  Est. cost (USD):   ${llm_usage.get('estimated_cost_usd', 0):.4f}")
        print(f"  Wall time:         {elapsed:>7.1f}s")
        print()

    print(DOUBLE_SEP)
    print("  Done.")
    print(DOUBLE_SEP)


def _run_offline(query: str) -> None:
    """Demonstrate the pipeline flow with mock data (no API key needed)."""
    _suppress_noisy_loggers()
    os.environ.setdefault("CHROMA_PERSIST_DIR", tempfile.mkdtemp())

    from fastapi.testclient import TestClient
    from src.main import app

    _print_header()
    print(f"  Query: {query}")
    print("  Mode:  OFFLINE (mock data, no LLM calls)\n")

    mock_subquestions = [
        "What are the key provisions of the EU AI Act?",
        "How does the US approach AI regulation at the federal level?",
        "What are the enforcement mechanisms and penalties in each approach?",
        "How do these regulatory frameworks affect tech startups?",
    ]

    mock_answers = [
        (
            "The EU AI Act, adopted March 2024, classifies AI systems into four "
            "risk tiers: unacceptable (banned), high-risk (strict compliance), "
            "limited risk (transparency), and minimal risk (voluntary codes). "
            "High-risk systems must undergo conformity assessments."
        ),
        (
            "The US has no comprehensive federal AI law. Regulation is "
            "sector-specific: the FDA regulates AI in healthcare, the SEC in "
            "finance. Executive Order 14110 (Oct 2023) sets voluntary guidelines "
            "and reporting requirements for frontier models."
        ),
        (
            "EU enforcement: fines up to 7% of global annual turnover or EUR 35M. "
            "National authorities supervise compliance. US enforcement: varies by "
            "sector; FTC can bring actions under existing consumer protection law. "
            "No dedicated AI enforcement body exists federally."
        ),
        (
            "EU: higher compliance costs for startups building high-risk AI; "
            "regulatory sandboxes partially offset this. US: lighter regulatory "
            "burden encourages experimentation but creates uncertainty. Startups "
            "operating in both markets must design for EU compliance as the "
            "higher standard."
        ),
    ]

    with TestClient(app) as client:
        client.post("/memory/reset")

        _print_section("Step 1: Query Decomposition (mock)")
        print(f"  Generated {len(mock_subquestions)} sub-questions:\n")
        for i, sq in enumerate(mock_subquestions, 1):
            print(f"    {i}. {sq}")

        _print_section("Step 2: Research (mock — stored in ChromaDB)")
        for i, (sq, answer) in enumerate(zip(mock_subquestions, mock_answers), 1):
            resp = client.post("/memory/store", json={
                "text": answer,
                "query": sq,
                "session_id": "offline-demo",
            })
            result = resp.json()
            budget = result["budget"]
            print(f"\n  [{i}/{len(mock_subquestions)}] {sq}")
            print(f"       Stored: {result['stored_tokens']:,} tokens | "
                  f"Budget: {budget['tokens_used']:,} / {budget['max_per_session']:,}")

        _print_section("Step 3: Retrieval (vector similarity)")
        resp = client.post("/memory/retrieve", json={
            "query": query,
            "top_k": 10,
            "session_id": "offline-demo",
        })
        retrieval = resp.json()
        for i, r in enumerate(retrieval["results"], 1):
            print(f"\n  [Source {i}] relevance={r['relevance']:.4f}  tokens={r['tokens']}")
            print(f"       {r['content'][:100]}...")

        _print_section("Budget Report")
        budget = retrieval["budget"]
        print(f"  Tokens used:       {budget['tokens_used']:>8,} / {budget['max_per_session']:,}")
        print(f"  Tokens remaining:  {budget['tokens_remaining']:>8,}")
        print(f"  Sub-queries done:  {budget['subquery_count']:>8}")
        print(f"  LLM calls:                0  (offline mode)")
        print(f"  Est. cost (USD):     $0.0000  (offline mode)")
        print()

    print(DOUBLE_SEP)
    print("  Done. Run without --offline to use the live LLM API.")
    print(DOUBLE_SEP)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Deep Research Agent (G3) — CLI Demo",
    )
    parser.add_argument("query", nargs="?", default=None, help="Research question")
    parser.add_argument("--demo", action="store_true", help="Use the built-in demo question")
    parser.add_argument("--offline", action="store_true", help="Run with mock data (no API key needed)")
    args = parser.parse_args()

    query = args.query or (DEMO_QUERY if args.demo else None)
    if not query:
        parser.error("Provide a query or use --demo")

    if args.offline:
        _run_offline(query)
    else:
        _run_live(query)


if __name__ == "__main__":
    main()
