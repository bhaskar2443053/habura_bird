"""Frozen DINOv2 baseline embedder (day-one matching before any training). Needs the `ml` extra."""

from __future__ import annotations

import numpy as np

from birdreid.embed.base import l2_normalize


class DinoV2Embedder:
    def __init__(self, variant: str = "dinov2_vits14", device: str = "cpu"):
        import torch
        from torchvision import transforms

        self._torch = torch
        self.name = variant
        self.version = "frozen-hub"
        self.device = device
        self.model = torch.hub.load("facebookresearch/dinov2", variant).to(device).eval()
        self.dim = int(self.model.embed_dim)
        self.transform = transforms.Compose(
            [
                transforms.ToPILImage(),
                transforms.Resize(224),
                transforms.CenterCrop(224),
                transforms.ToTensor(),
                transforms.Normalize((0.485, 0.456, 0.406), (0.229, 0.224, 0.225)),
            ]
        )

    def embed(self, crops: list[np.ndarray]) -> np.ndarray:
        torch = self._torch
        rgb = [np.repeat(c[..., None], 3, axis=-1) if c.ndim == 2 else c for c in crops]
        batch = torch.stack([self.transform(c) for c in rgb]).to(self.device)
        with torch.no_grad():
            feats = self.model(batch).cpu().numpy()
        return l2_normalize(feats)
