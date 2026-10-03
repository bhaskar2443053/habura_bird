"""Classifies each uploaded photo into a body region.

The app supplies a hint (the checklist step the photo was taken in). The server always
re-classifies, because handlers also take ad-hoc photos. Disagreement or low confidence sends
the photo to the review queue. With no labelled data yet the default backend is zero-shot CLIP;
it is replaced by a fine-tuned head once reviewers have labelled a few hundred photos.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import numpy as np

from birdreid.types import Region

ZERO_SHOT_PROMPTS: dict[Region, str] = {
    Region.IRIS: "an extreme close-up photo of a bird's eye and iris",
    Region.FACE: "a close-up photo of a bustard's head from the side",
    Region.BEAK: "a close-up photo of a bird's beak",
    Region.PLUMAGE_DORSAL: "a photo of the patterned back feathers of a bustard",
    Region.PLUMAGE_VENTRAL: "a photo of the breast and neck feathers of a bustard",
    Region.WING: "a photo of a spread bird wing",
    Region.TAIL: "a photo of a bird's tail feathers",
    Region.FEET: "a close-up photo of a bird's leg and scaly toes",
    Region.RING: "a close-up photo of a numbered metal or plastic ring on a bird's leg",
    Region.OTHER: "a photo with no bird body part in focus",
}


class ClassifierBackend(Protocol):
    def probabilities(self, image: np.ndarray) -> dict[Region, float]: ...


@dataclass(frozen=True)
class RegionLabel:
    region: Region
    confidence: float
    hint: Region | None
    needs_review: bool


class RegionClassifier:
    def __init__(self, backend: ClassifierBackend, min_confidence: float = 0.6):
        self.backend = backend
        self.min_confidence = min_confidence

    def classify(self, image: np.ndarray, hint: Region | None = None) -> RegionLabel:
        probs = self.backend.probabilities(image)
        region, confidence = max(probs.items(), key=lambda kv: kv[1])
        needs_review = confidence < self.min_confidence or (hint is not None and hint != region)
        return RegionLabel(region, confidence, hint, needs_review)


class ZeroShotClipBackend:
    """CLIP zero-shot backend. Requires the `ml` extra (torch + open_clip)."""

    def __init__(self, model_name: str = "ViT-B-32", pretrained: str = "laion2b_s34b_b79k"):
        import open_clip
        import torch

        self._torch = torch
        self.model, _, self.preprocess = open_clip.create_model_and_transforms(
            model_name, pretrained=pretrained
        )
        self.model.eval()
        tokenizer = open_clip.get_tokenizer(model_name)
        self.regions = list(ZERO_SHOT_PROMPTS)
        with torch.no_grad():
            text = self.model.encode_text(tokenizer([ZERO_SHOT_PROMPTS[r] for r in self.regions]))
            self.text = text / text.norm(dim=-1, keepdim=True)

    def probabilities(self, image: np.ndarray) -> dict[Region, float]:
        from PIL import Image

        torch = self._torch
        x = self.preprocess(Image.fromarray(image)).unsqueeze(0)
        with torch.no_grad():
            feat = self.model.encode_image(x)
            feat = feat / feat.norm(dim=-1, keepdim=True)
            probs = (100.0 * feat @ self.text.T).softmax(dim=-1)[0].tolist()
        return dict(zip(self.regions, probs, strict=True))
