"""Thin wrapper around the HKBU GenAI (Azure OpenAI-compatible) API."""

from __future__ import annotations

import logging
from typing import Any

import httpx

from .config import settings

logger = logging.getLogger(__name__)

# Approximate GPT-4.1 pricing (USD per 1M tokens)
_INPUT_PRICE = 2.00
_OUTPUT_PRICE = 8.00


class LLMClient:
    """Stateless LLM caller with cumulative token-usage and cost tracking."""

    def __init__(self) -> None:
        self._url = (
            f"{settings.hkbu_base_url}/deployments/{settings.hkbu_model_name}"
            f"/chat/completions?api-version={settings.hkbu_api_version}"
        )
        self._headers = {
            "Content-Type": "application/json",
            "api-key": settings.hkbu_api_key,
        }
        self.total_input_tokens = 0
        self.total_output_tokens = 0
        self.call_count = 0

    # -- core ---------------------------------------------------------------

    async def chat(
        self,
        system: str,
        user: str,
        *,
        temperature: float = 0.4,
        max_tokens: int = 2000,
    ) -> str:
        payload = self._build_payload(system, user, temperature, max_tokens)
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(self._url, json=payload, headers=self._headers)
        return self._handle_response(resp)

    def chat_sync(
        self,
        system: str,
        user: str,
        *,
        temperature: float = 0.4,
        max_tokens: int = 2000,
    ) -> str:
        payload = self._build_payload(system, user, temperature, max_tokens)
        resp = httpx.post(self._url, json=payload, headers=self._headers, timeout=60)
        return self._handle_response(resp)

    # -- helpers ------------------------------------------------------------

    def _build_payload(
        self, system: str, user: str, temperature: float, max_tokens: int
    ) -> dict[str, Any]:
        return {
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": temperature,
            "max_tokens": max_tokens,
        }

    def _handle_response(self, resp: httpx.Response) -> str:
        if resp.status_code != 200:
            raise RuntimeError(f"LLM API error {resp.status_code}: {resp.text}")

        data = resp.json()
        usage = data.get("usage", {})
        inp = usage.get("prompt_tokens", 0)
        out = usage.get("completion_tokens", 0)
        self.total_input_tokens += inp
        self.total_output_tokens += out
        self.call_count += 1
        logger.info("LLM call #%d  in=%d  out=%d", self.call_count, inp, out)

        return data["choices"][0]["message"]["content"]

    # -- cost tracking ------------------------------------------------------

    @property
    def estimated_cost_usd(self) -> float:
        return (
            self.total_input_tokens * _INPUT_PRICE
            + self.total_output_tokens * _OUTPUT_PRICE
        ) / 1_000_000

    def usage_summary(self) -> dict[str, Any]:
        return {
            "llm_calls": self.call_count,
            "total_input_tokens": self.total_input_tokens,
            "total_output_tokens": self.total_output_tokens,
            "estimated_cost_usd": round(self.estimated_cost_usd, 6),
        }

    def reset_usage(self) -> None:
        self.total_input_tokens = 0
        self.total_output_tokens = 0
        self.call_count = 0
