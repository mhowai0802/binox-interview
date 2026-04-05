"""FastAPI service exposing memory management + research pipeline endpoints."""

from __future__ import annotations

import json
import logging
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from .config import settings
from .constraints import count_tokens, truncate_to_budget
from .llm import LLMClient
from .memory import MemoryManager
from .search import format_search_context, web_search

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-20s  %(levelname)-5s  %(message)s",
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Lifespan — initialise shared objects once
# ---------------------------------------------------------------------------

memory: MemoryManager | None = None
llm: LLMClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global memory, llm
    memory = MemoryManager()
    llm = LLMClient()
    logger.info("Memory service started (budget %d/%d tokens per sub/session)",
                settings.max_tokens_per_subquery, settings.max_tokens_per_session)
    yield


app = FastAPI(
    title="Deep Research Agent — Memory Service",
    version="2.0.0",
    lifespan=lifespan,
)


def _mem() -> MemoryManager:
    assert memory is not None
    return memory


def _llm() -> LLMClient:
    assert llm is not None
    return llm


# ---------------------------------------------------------------------------
# Request / Response schemas
# ---------------------------------------------------------------------------


class StoreRequest(BaseModel):
    text: str
    query: str
    session_id: str | None = None
    metadata: dict[str, Any] | None = None


class RetrieveRequest(BaseModel):
    query: str
    top_k: int = Field(default=5, ge=1, le=20)
    session_id: str | None = None


class SummarizeRequest(BaseModel):
    text: str
    max_tokens: int | None = None
    focus: str = Field(
        default="",
        description="Optional focus hint so the LLM knows what to keep.",
    )


class DecomposeRequest(BaseModel):
    query: str


class ResearchSubqueryRequest(BaseModel):
    subquery: str
    session_id: str | None = None


class PipelineRequest(BaseModel):
    """Run the full decompose → research → synthesise pipeline in one call."""
    query: str
    session_id: str | None = "pipeline"
    top_k: int = Field(default=10, ge=1, le=20)


# ---------------------------------------------------------------------------
# Endpoints — memory layer
# ---------------------------------------------------------------------------


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/memory/store")
async def store_memory(req: StoreRequest):
    return _mem().store(
        text=req.text,
        query=req.query,
        session_id=req.session_id,
        metadata=req.metadata,
    )


@app.post("/memory/retrieve")
async def retrieve_memory(req: RetrieveRequest):
    return _mem().retrieve(
        query=req.query,
        top_k=req.top_k,
        session_id=req.session_id,
    )


@app.get("/memory/budget")
async def get_budget():
    return _mem().get_budget()


@app.post("/memory/reset")
async def reset_session():
    _llm().reset_usage()
    return _mem().reset_session()


# ---------------------------------------------------------------------------
# Endpoints — LLM-powered research
# ---------------------------------------------------------------------------


@app.post("/memory/summarize")
async def summarize(req: SummarizeRequest):
    """Call the HKBU LLM to compress *text* within the token budget."""
    max_tok = req.max_tokens or settings.max_tokens_per_subquery

    if count_tokens(req.text) <= max_tok:
        return {
            "summary": req.text,
            "tokens": count_tokens(req.text),
            "was_summarized": False,
        }

    focus_hint = f" Focus on: {req.focus}" if req.focus else ""
    system_msg = (
        "You are a precise research summariser. Compress the following text "
        f"into at most {max_tok} tokens while preserving all key facts, "
        f"figures, and citations.{focus_hint}"
    )

    try:
        summary = await _llm().chat(system_msg, req.text, temperature=0.3, max_tokens=max_tok)
    except RuntimeError as exc:
        raise HTTPException(502, str(exc)) from exc

    summary = truncate_to_budget(summary, max_tok)
    return {
        "summary": summary,
        "tokens": count_tokens(summary),
        "was_summarized": True,
    }


@app.post("/decompose")
async def decompose_query(req: DecomposeRequest):
    """Break a complex research question into sub-questions using the LLM."""
    max_sub = settings.max_subquestions

    system_msg = (
        "You are a research planning assistant. Given a complex query, break it "
        f"into at most {max_sub} independent sub-questions that together cover "
        "the full scope. Return ONLY a JSON array of strings, nothing else. "
        'Example: ["sub-question 1", "sub-question 2"]'
    )

    try:
        raw = await _llm().chat(system_msg, req.query, temperature=0.4, max_tokens=500)
    except RuntimeError as exc:
        raise HTTPException(502, str(exc)) from exc

    try:
        subquestions = json.loads(raw)
    except json.JSONDecodeError:
        subquestions = [line.strip("- ") for line in raw.splitlines() if line.strip()]

    return {
        "original_query": req.query,
        "subquestions": subquestions[:max_sub],
        "count": len(subquestions[:max_sub]),
    }


@app.post("/research")
async def research_subquery(req: ResearchSubqueryRequest):
    """Execute a single sub-query: optionally web-search, then LLM answer, store.

    When ``ENABLE_WEB_SEARCH=true`` (default), the agent first searches
    the web via DuckDuckGo and feeds the results as grounding context to
    the LLM.  This makes the agent a *real* research tool rather than a
    wrapper around parametric knowledge.
    """
    budget = _mem().get_budget()
    if budget["is_exhausted"]:
        return {
            "status": "skipped",
            "reason": "session token budget exhausted",
            "budget": budget,
        }

    allowed = min(settings.max_tokens_per_subquery, budget["tokens_remaining"])

    search_ctx = ""
    search_results: list[dict] = []
    if settings.enable_web_search:
        search_results = web_search(req.subquery, max_results=settings.web_search_max_results)
        search_ctx = format_search_context(search_results)

    if search_ctx:
        system_msg = (
            "You are a research assistant. Answer the following question using "
            "the web search results provided below as your PRIMARY source. "
            "Supplement with your own knowledge only when the search results are "
            "insufficient. Be concise — your answer must fit within roughly "
            f"{allowed} tokens. Cite sources as [Web N].\n\n"
            f"--- WEB SEARCH RESULTS ---\n{search_ctx}"
        )
    else:
        system_msg = (
            "You are a research assistant. Answer the following question with "
            "factual, well-sourced information. Be concise — your answer must "
            f"fit within roughly {allowed} tokens. Include key facts, figures, "
            "and cite sources where possible."
        )

    try:
        answer = await _llm().chat(system_msg, req.subquery, temperature=0.5, max_tokens=allowed)
    except RuntimeError as exc:
        raise HTTPException(502, str(exc)) from exc

    answer = truncate_to_budget(answer, allowed)

    store_result = _mem().store(
        text=answer,
        query=req.subquery,
        session_id=req.session_id,
    )

    return {
        "subquery": req.subquery,
        "answer": answer,
        "tokens": count_tokens(answer),
        "web_sources": len(search_results),
        "store": store_result,
    }


@app.post("/synthesize")
async def synthesize(req: RetrieveRequest):
    """Retrieve relevant context and synthesise a final answer."""
    retrieval = _mem().retrieve(
        query=req.query,
        top_k=req.top_k,
        session_id=req.session_id,
    )

    context_parts = [
        f"[Source {i+1}] (relevance {r['relevance']})\n{r['content']}"
        for i, r in enumerate(retrieval["results"])
    ]
    context_block = "\n\n".join(context_parts)

    system_msg = (
        "You are a senior research analyst. Using ONLY the provided research "
        "context below, write a comprehensive answer to the user's question. "
        "Cite sources as [Source N]. If the context is insufficient, state "
        "what is missing.\n\n--- RESEARCH CONTEXT ---\n" + context_block
    )

    try:
        final_answer = await _llm().chat(system_msg, req.query, temperature=0.4, max_tokens=2000)
    except RuntimeError as exc:
        raise HTTPException(502, str(exc)) from exc

    return {
        "query": req.query,
        "answer": final_answer,
        "sources_used": len(retrieval["results"]),
        "context_tokens": retrieval["total_tokens"],
        "budget": _mem().get_budget(),
        "llm_usage": _llm().usage_summary(),
    }


# ---------------------------------------------------------------------------
# Full pipeline endpoint — one call runs the entire research flow
# ---------------------------------------------------------------------------


@app.post("/pipeline")
async def run_pipeline(req: PipelineRequest):
    """Execute the complete research pipeline in a single request.

    Decompose → Research each sub-question → Synthesise → Return report
    with full budget and cost breakdown.
    """
    logger.info("Pipeline started for query: %s", req.query[:80])

    _mem().reset_session()
    _llm().reset_usage()

    decomposition = (await decompose_query(DecomposeRequest(query=req.query)))
    subquestions = decomposition["subquestions"]
    logger.info("Decomposed into %d sub-questions", len(subquestions))

    research_results: list[dict] = []
    for i, sq in enumerate(subquestions, 1):
        logger.info("Researching sub-question %d/%d: %s", i, len(subquestions), sq[:60])
        result = await research_subquery(
            ResearchSubqueryRequest(subquery=sq, session_id=req.session_id)
        )
        research_results.append(result)
        if result.get("status") == "skipped":
            logger.warning("Budget exhausted after sub-question %d", i)
            break

    synthesis = await synthesize(
        RetrieveRequest(query=req.query, top_k=req.top_k, session_id=req.session_id)
    )

    logger.info("Pipeline complete — %s", _llm().usage_summary())

    return {
        "query": req.query,
        "subquestions": subquestions,
        "research_results": research_results,
        "synthesis": synthesis,
        "budget": _mem().get_budget(),
        "llm_usage": _llm().usage_summary(),
    }
