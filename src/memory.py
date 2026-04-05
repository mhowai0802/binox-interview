"""Memory manager backed by ChromaDB for episodic vector storage."""

from __future__ import annotations

import time
import uuid
from typing import Any

import chromadb

from .config import settings
from .constraints import SessionBudget, count_tokens, truncate_to_budget


class MemoryManager:
    """Stores, retrieves, and summarises research chunks under a token budget."""

    def __init__(self) -> None:
        self._client = chromadb.PersistentClient(path=settings.chroma_persist_dir)
        self._collection = self._client.get_or_create_collection(
            name="research_memory",
            metadata={"hnsw:space": "cosine"},
        )
        self._budget = SessionBudget(
            max_per_subquery=settings.max_tokens_per_subquery,
            max_per_session=settings.max_tokens_per_session,
        )

    # -- store ------------------------------------------------------------

    def store(
        self,
        text: str,
        query: str,
        session_id: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> dict:
        """Persist a summarised research chunk and update the budget."""
        token_count = count_tokens(text)
        fitted = truncate_to_budget(text, self._budget.max_per_subquery)
        fitted_tokens = count_tokens(fitted)

        doc_id = str(uuid.uuid4())
        meta: dict[str, Any] = {
            "query": query,
            "session_id": session_id or "",
            "timestamp": time.time(),
            "token_count": fitted_tokens,
            **(metadata or {}),
        }

        self._collection.add(
            ids=[doc_id],
            documents=[fitted],
            metadatas=[meta],
        )
        self._budget.record(fitted_tokens)

        return {
            "id": doc_id,
            "stored_tokens": fitted_tokens,
            "original_tokens": token_count,
            "truncated": token_count != fitted_tokens,
            "budget": self._budget.to_dict(),
        }

    # -- retrieve ---------------------------------------------------------

    def retrieve(
        self,
        query: str,
        top_k: int = 5,
        session_id: str | None = None,
    ) -> dict:
        """Return the most relevant stored summaries for *query*."""
        where_filter = {"session_id": session_id} if session_id else None
        results = self._collection.query(
            query_texts=[query],
            n_results=min(top_k, self._collection.count() or 1),
            where=where_filter,
        )

        documents: list[dict] = []
        total_tokens = 0
        for doc, meta, dist in zip(
            results["documents"][0],
            results["metadatas"][0],
            results["distances"][0],
        ):
            tokens = count_tokens(doc)
            total_tokens += tokens
            documents.append({
                "content": doc,
                "metadata": meta,
                "relevance": round(1 - dist, 4),
                "tokens": tokens,
            })

        return {
            "results": documents,
            "total_tokens": total_tokens,
            "budget": self._budget.to_dict(),
        }

    # -- budget -----------------------------------------------------------

    def get_budget(self) -> dict:
        return self._budget.to_dict()

    def reset_session(self) -> dict:
        self._budget.reset()
        return self._budget.to_dict()
