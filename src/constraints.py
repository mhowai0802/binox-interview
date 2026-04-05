"""Token budget tracking and constraint enforcement."""

import tiktoken

_encoder = tiktoken.get_encoding("cl100k_base")


def count_tokens(text: str) -> int:
    """Return the token count for *text* using the cl100k_base encoding."""
    return len(_encoder.encode(text))


def truncate_to_budget(text: str, max_tokens: int) -> str:
    """Truncate *text* so it fits within *max_tokens*.

    Returns the original string when it already fits; otherwise returns
    a decoded version trimmed to the budget.
    """
    tokens = _encoder.encode(text)
    if len(tokens) <= max_tokens:
        return text
    return _encoder.decode(tokens[:max_tokens])


class SessionBudget:
    """Tracks cumulative token usage for one research session."""

    def __init__(self, max_per_subquery: int, max_per_session: int):
        self.max_per_subquery = max_per_subquery
        self.max_per_session = max_per_session
        self.tokens_used: int = 0
        self.subquery_count: int = 0

    # -- queries ----------------------------------------------------------

    @property
    def tokens_remaining(self) -> int:
        return max(0, self.max_per_session - self.tokens_used)

    @property
    def is_exhausted(self) -> bool:
        return self.tokens_remaining == 0

    # -- mutations --------------------------------------------------------

    def record(self, tokens: int) -> None:
        self.tokens_used += tokens
        self.subquery_count += 1

    def reset(self) -> None:
        self.tokens_used = 0
        self.subquery_count = 0

    # -- serialisation ----------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "tokens_used": self.tokens_used,
            "tokens_remaining": self.tokens_remaining,
            "max_per_subquery": self.max_per_subquery,
            "max_per_session": self.max_per_session,
            "subquery_count": self.subquery_count,
            "is_exhausted": self.is_exhausted,
        }
