"""Unit tests for the memory constraint service."""

import os
import shutil
import tempfile

import pytest
from fastapi.testclient import TestClient

_tmp = tempfile.mkdtemp()
os.environ["CHROMA_PERSIST_DIR"] = _tmp

from src.constraints import SessionBudget, count_tokens, truncate_to_budget
from src.main import app


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


# -- constraints unit tests -------------------------------------------------


class TestCountTokens:
    def test_empty_string(self):
        assert count_tokens("") == 0

    def test_simple_sentence(self):
        tokens = count_tokens("Hello, world!")
        assert 2 <= tokens <= 5

    def test_longer_text(self):
        text = "The quick brown fox jumps over the lazy dog. " * 10
        assert count_tokens(text) > 50


class TestTruncateToBudget:
    def test_short_text_unchanged(self):
        text = "Short text"
        assert truncate_to_budget(text, 100) == text

    def test_long_text_truncated(self):
        text = "word " * 500
        result = truncate_to_budget(text, 50)
        assert count_tokens(result) <= 50


class TestSessionBudget:
    def test_initial_state(self):
        b = SessionBudget(max_per_subquery=100, max_per_session=500)
        assert b.tokens_used == 0
        assert b.tokens_remaining == 500
        assert not b.is_exhausted

    def test_record(self):
        b = SessionBudget(max_per_subquery=100, max_per_session=500)
        b.record(200)
        assert b.tokens_used == 200
        assert b.tokens_remaining == 300

    def test_exhaustion(self):
        b = SessionBudget(max_per_subquery=100, max_per_session=500)
        b.record(500)
        assert b.is_exhausted

    def test_reset(self):
        b = SessionBudget(max_per_subquery=100, max_per_session=500)
        b.record(300)
        b.reset()
        assert b.tokens_used == 0
        assert b.tokens_remaining == 500


# -- API endpoint tests -----------------------------------------------------


class TestHealthEndpoint:
    def test_health(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"


class TestBudgetEndpoint:
    def test_get_budget(self, client):
        client.post("/memory/reset")
        resp = client.get("/memory/budget")
        assert resp.status_code == 200
        data = resp.json()
        assert "tokens_used" in data
        assert "tokens_remaining" in data


class TestStoreAndRetrieve:
    def test_store_and_retrieve(self, client):
        client.post("/memory/reset")
        store_resp = client.post("/memory/store", json={
            "text": "The EU AI Act was formally adopted in March 2024.",
            "query": "EU AI regulation timeline",
            "session_id": "test-session",
        })
        assert store_resp.status_code == 200
        assert store_resp.json()["stored_tokens"] > 0

        retrieve_resp = client.post("/memory/retrieve", json={
            "query": "When was the EU AI Act adopted?",
            "top_k": 3,
            "session_id": "test-session",
        })
        assert retrieve_resp.status_code == 200
        results = retrieve_resp.json()["results"]
        assert len(results) >= 1
        assert "EU AI Act" in results[0]["content"]


class TestResetEndpoint:
    def test_reset(self, client):
        client.post("/memory/store", json={
            "text": "Some research data",
            "query": "test",
        })
        resp = client.post("/memory/reset")
        assert resp.status_code == 200
        assert resp.json()["tokens_used"] == 0


# -- cleanup ----------------------------------------------------------------

@pytest.fixture(autouse=True, scope="session")
def cleanup():
    yield
    if os.path.isdir(_tmp):
        shutil.rmtree(_tmp, ignore_errors=True)
