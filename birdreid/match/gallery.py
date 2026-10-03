"""In-memory per-region gallery with cosine kNN. Swap for pgvector once data grows."""

from __future__ import annotations

from collections import defaultdict

import numpy as np

from birdreid.embed.base import l2_normalize
from birdreid.types import Region


class Gallery:
    def __init__(self) -> None:
        self._vectors: dict[Region, list[np.ndarray]] = defaultdict(list)
        self._owners: dict[Region, list[str]] = defaultdict(list)

    def add(self, individual_id: str, region: Region, embedding: np.ndarray) -> None:
        self._vectors[region].append(l2_normalize(embedding))
        self._owners[region].append(individual_id)

    def individuals(self) -> set[str]:
        return {i for owners in self._owners.values() for i in owners}

    def region_scores(self, region: Region, query: np.ndarray) -> dict[str, float]:
        """Best cosine similarity per individual for one region (max over their crops)."""
        if not self._vectors[region]:
            return {}
        sims = np.stack(self._vectors[region]) @ l2_normalize(query)
        best: dict[str, float] = {}
        for owner, sim in zip(self._owners[region], sims.tolist(), strict=True):
            best[owner] = max(best.get(owner, -1.0), sim)
        return best

    def query(self, embeddings: dict[Region, np.ndarray]) -> dict[str, dict[Region, float]]:
        """Per-individual, per-region scores for a query session's available regions."""
        out: dict[str, dict[Region, float]] = defaultdict(dict)
        for region, emb in embeddings.items():
            for ind, score in self.region_scores(region, emb).items():
                out[ind][region] = score
        return dict(out)
