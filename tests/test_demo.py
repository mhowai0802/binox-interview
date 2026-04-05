"""End-to-end demo test for the research agent pipeline.

This test exercises the full decompose → research → synthesise flow
against the local memory service. Since it requires a live LLM API key,
it is skipped by default. Run with:

    HKBU_API_KEY=<your-key> python -m pytest tests/test_demo.py -v -s

The -s flag shows the printed output so you can see the full research report.
"""

import os
import tempfile

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("CHROMA_PERSIST_DIR", tempfile.mkdtemp())

from src.main import app

DEMO_QUERY = (
    "Compare the economic impact of AI regulation in the EU (AI Act) "
    "vs the US approach. What are the key differences in enforcement "
    "mechanisms, and how might they affect tech startups operating in "
    "both markets?"
)

requires_api_key = pytest.mark.skipif(
    not os.environ.get("HKBU_API_KEY"),
    reason="HKBU_API_KEY not set — skipping live demo test",
)


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


@requires_api_key
class TestFullPipeline:
    """Run the complete research pipeline against the live LLM."""

    def test_end_to_end(self, client):
        # Step 1: Reset
        resp = client.post("/memory/reset")
        assert resp.status_code == 200
        print("\n=== SESSION RESET ===")
        print(resp.json())

        # Step 2: Decompose
        resp = client.post("/decompose", json={"query": DEMO_QUERY})
        assert resp.status_code == 200
        decomposition = resp.json()
        subquestions = decomposition["subquestions"]
        print(f"\n=== DECOMPOSED INTO {len(subquestions)} SUB-QUESTIONS ===")
        for i, sq in enumerate(subquestions, 1):
            print(f"  {i}. {sq}")

        assert 2 <= len(subquestions) <= 5

        # Step 3: Research each sub-question
        for i, sq in enumerate(subquestions, 1):
            resp = client.post("/research", json={
                "subquery": sq,
                "session_id": "demo",
            })
            assert resp.status_code == 200
            result = resp.json()
            print(f"\n=== RESEARCH SUB-Q {i} ===")
            print(f"  Tokens used: {result.get('tokens', 'N/A')}")
            print(f"  Budget: {result.get('store', {}).get('budget', result.get('budget', {}))}")

            if result.get("status") == "skipped":
                print(f"  SKIPPED: {result['reason']}")
                break

        # Step 4: Check budget
        resp = client.get("/memory/budget")
        assert resp.status_code == 200
        budget = resp.json()
        print(f"\n=== BUDGET AFTER RESEARCH ===")
        print(f"  Tokens used:      {budget['tokens_used']}")
        print(f"  Tokens remaining:  {budget['tokens_remaining']}")
        print(f"  Sub-queries done:  {budget['subquery_count']}")
        assert budget["tokens_used"] <= budget["max_per_session"]

        # Step 5: Synthesise
        resp = client.post("/synthesize", json={
            "query": DEMO_QUERY,
            "top_k": 10,
            "session_id": "demo",
        })
        assert resp.status_code == 200
        synthesis = resp.json()
        print(f"\n=== FINAL ANSWER ===")
        print(synthesis["answer"])
        print(f"\n  Sources used:    {synthesis['sources_used']}")
        print(f"  Context tokens:  {synthesis['context_tokens']}")
        print(f"  Budget:          {synthesis['budget']}")

        assert len(synthesis["answer"]) > 100
        assert synthesis["sources_used"] >= 1


class TestOfflinePipeline:
    """Test the pipeline mechanics without LLM calls."""

    def test_store_retrieve_synthesise_flow(self, client):
        client.post("/memory/reset")

        chunks = [
            ("The EU AI Act classifies AI systems by risk level.", "EU AI Act risk classification"),
            ("The US has no federal AI law; regulation is sector-specific.", "US AI regulation approach"),
            ("EU enforcement includes fines up to 7% of global turnover.", "EU AI enforcement mechanisms"),
        ]

        for text, query in chunks:
            resp = client.post("/memory/store", json={
                "text": text,
                "query": query,
                "session_id": "offline-demo",
            })
            assert resp.status_code == 200

        resp = client.post("/memory/retrieve", json={
            "query": "Compare EU and US AI regulation enforcement",
            "top_k": 5,
            "session_id": "offline-demo",
        })
        assert resp.status_code == 200
        results = resp.json()["results"]
        assert len(results) == 3

        budget = client.get("/memory/budget").json()
        assert budget["tokens_used"] > 0
        assert budget["subquery_count"] == 3

        print("\n=== OFFLINE DEMO ===")
        print(f"  Stored {len(chunks)} chunks")
        print(f"  Retrieved {len(results)} results")
        print(f"  Budget used: {budget['tokens_used']} / {budget['max_per_session']}")
