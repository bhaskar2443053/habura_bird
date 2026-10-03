"""Embedding interface. One embedder per region; versions are stored with every vector."""

from __future__ import annotations

from typing import Protocol

import numpy as np


class Embedder(Protocol):
    name: str
    version: str
    dim: int

    def embed(self, crops: list[np.ndarray]) -> np.ndarray:
        """Return an (N, dim) float32 array of L2-normalised embeddings."""
        ...


def l2_normalize(x: np.ndarray, eps: float = 1e-12) -> np.ndarray:
    x = np.asarray(x, dtype=np.float32)
    return x / np.maximum(np.linalg.norm(x, axis=-1, keepdims=True), eps)
