"""Cheap image-quality checks used as the capture gate (mirrored on-device in the iOS app)."""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from birdreid.capture.protocol import QualityThresholds
from birdreid.types import Frame


def to_gray(pixels: np.ndarray) -> np.ndarray:
    img = pixels.astype(np.float32)
    if pixels.dtype == np.uint16:
        img /= 257.0
    if img.ndim == 3:
        img = img[..., :3] @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    return img


def sharpness(gray: np.ndarray) -> float:
    """Variance of the 4-neighbour Laplacian; higher means sharper."""
    lap = (
        -4 * gray[1:-1, 1:-1] + gray[:-2, 1:-1] + gray[2:, 1:-1] + gray[1:-1, :-2] + gray[1:-1, 2:]
    )
    return float(lap.var())


def glare_ratio(gray: np.ndarray, level: float = 250.0) -> float:
    """Fraction of saturated pixels (specular highlights, e.g. on the eye)."""
    return float((gray >= level).mean())


@dataclass
class QualityReport:
    sharpness: float
    glare_ratio: float
    brightness: float
    short_side_px: int
    failures: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.failures

    @property
    def score(self) -> float:
        """Ranking score among passing shots of the same view."""
        return self.sharpness * (1.0 - self.glare_ratio)


def assess(frame: Frame, thresholds: QualityThresholds) -> QualityReport:
    gray = to_gray(frame.pixels)
    report = QualityReport(
        sharpness=sharpness(gray),
        glare_ratio=glare_ratio(gray),
        brightness=float(gray.mean()),
        short_side_px=min(frame.height, frame.width),
    )
    if report.sharpness < thresholds.min_sharpness:
        report.failures.append("blurry")
    if report.glare_ratio > thresholds.max_glare_ratio:
        report.failures.append("glare")
    if report.brightness < thresholds.min_brightness:
        report.failures.append("too_dark")
    if report.brightness > thresholds.max_brightness:
        report.failures.append("too_bright")
    if report.short_side_px < thresholds.min_short_side_px:
        report.failures.append("too_small")
    return report
