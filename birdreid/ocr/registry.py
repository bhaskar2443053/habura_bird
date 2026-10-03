"""Validates OCR'd ring codes against the site's ring registry.

A confident match links a capture session to an Individual, which is the main source of
ground-truth labels while no labelled ReID data exists.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# Characters OCR commonly confuses on engraved rings, mapped to a canonical form.
CONFUSABLE = str.maketrans({"O": "0", "Q": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "B": "8"})


def normalize(code: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", code.upper())


def _canonical(code: str) -> str:
    return normalize(code).translate(CONFUSABLE)


def edit_distance(a: str, b: str) -> int:
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


@dataclass(frozen=True)
class RingMatch:
    read: str
    code: str | None
    distance: int
    status: str  # "exact" | "fuzzy" | "ambiguous" | "unknown" | "invalid_format"

    @property
    def confident(self) -> bool:
        return self.status in ("exact", "fuzzy")


class RingRegistry:
    """Known ring codes. `pattern` is the site's code format (placeholder until confirmed)."""

    def __init__(self, codes: list[str], pattern: str = r"^[A-Z0-9]{3,10}$", max_distance: int = 1):
        self.codes = {normalize(c) for c in codes}
        self._by_canonical: dict[str, set[str]] = {}
        for c in self.codes:
            self._by_canonical.setdefault(_canonical(c), set()).add(c)
        self.pattern = re.compile(pattern)
        self.max_distance = max_distance

    def match(self, read: str) -> RingMatch:
        code = normalize(read)
        if not self.pattern.match(code):
            return RingMatch(read, None, -1, "invalid_format")
        if code in self.codes:
            return RingMatch(read, code, 0, "exact")
        canonical = self._by_canonical.get(_canonical(code), set())
        if len(canonical) == 1:
            return RingMatch(read, next(iter(canonical)), 0, "fuzzy")
        scored = sorted((edit_distance(_canonical(code), _canonical(c)), c) for c in self.codes)
        close = [(d, c) for d, c in scored if d <= self.max_distance]
        if not close:
            return RingMatch(read, None, scored[0][0] if scored else -1, "unknown")
        if len(close) > 1 and close[0][0] == close[1][0]:
            return RingMatch(read, None, close[0][0], "ambiguous")
        return RingMatch(read, close[0][1], close[0][0], "fuzzy")
