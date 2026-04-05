"""Web search tool — DuckDuckGo (no API key required).

Falls back gracefully to an empty result list when the package is
missing or the network is unavailable, so the agent can still operate
using pure LLM knowledge.
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


def web_search(query: str, max_results: int = 5) -> list[dict[str, Any]]:
    """Return a list of ``{title, body, url}`` dicts from DuckDuckGo."""
    try:
        from duckduckgo_search import DDGS

        with DDGS() as ddgs:
            raw = list(ddgs.text(query, max_results=max_results))
        results = [
            {
                "title": r.get("title", ""),
                "body": r.get("body", ""),
                "url": r.get("href", ""),
            }
            for r in raw
        ]
        logger.info("Web search for %r → %d results", query, len(results))
        return results
    except ImportError:
        logger.warning("duckduckgo-search not installed; skipping web search")
        return []
    except Exception as exc:
        logger.warning("Web search failed (%s); returning empty results", exc)
        return []


def format_search_context(results: list[dict[str, Any]]) -> str:
    """Turn search results into an LLM-friendly context block."""
    if not results:
        return ""
    parts: list[str] = []
    for i, r in enumerate(results, 1):
        parts.append(f"[Web {i}] {r['title']}\n{r['body']}\nSource: {r['url']}")
    return "\n\n".join(parts)
