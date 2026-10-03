"""Score fusion across regions plus the open-set (new bird vs. known bird) decision."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum

from birdreid.types import Region

# Initial guesses; to be learned on validation data once ringed repeat captures exist.
DEFAULT_WEIGHTS: dict[Region, float] = {
    Region.IRIS: 3.0,
    Region.FEET: 2.0,
    Region.FACE: 1.5,
    Region.BEAK: 1.0,
    Region.PLUMAGE_DORSAL: 1.0,
    Region.PLUMAGE_VENTRAL: 1.0,
    Region.WING: 0.5,
    Region.TAIL: 0.5,
}


@dataclass
class FusionConfig:
    weights: dict[Region, float] = field(default_factory=lambda: dict(DEFAULT_WEIGHTS))
    accept: float = 0.80  # at or above: suggest this match
    review: float = 0.60  # between review and accept: human review; below: likely new bird


class Decision(StrEnum):
    MATCH = "match"
    REVIEW = "review"
    NEW = "new_individual"


def fuse(per_region: dict[Region, float], config: FusionConfig) -> tuple[float, float]:
    """Weighted mean over the regions present. Returns (score, coverage).

    Coverage is the fraction of total weight that was available, so a feet-only query still
    scores but is reported as low-coverage.
    """
    usable = {r: s for r, s in per_region.items() if config.weights.get(r, 0) > 0}
    total = sum(config.weights.values())
    present = sum(config.weights[r] for r in usable)
    if not usable or total == 0:
        return 0.0, 0.0
    score = sum(config.weights[r] * s for r, s in usable.items()) / present
    return score, present / total


def open_set_decision(
    candidates: dict[str, dict[Region, float]], config: FusionConfig
) -> tuple[Decision, list[tuple[str, float, float]]]:
    """Rank candidates by fused score and decide match / review / new individual."""
    ranked = sorted(
        ((ind, *fuse(scores, config)) for ind, scores in candidates.items()),
        key=lambda t: t[1],
        reverse=True,
    )
    if not ranked or ranked[0][1] < config.review:
        return Decision.NEW, ranked
    if ranked[0][1] >= config.accept:
        return Decision.MATCH, ranked
    return Decision.REVIEW, ranked
