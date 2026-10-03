"""Core value types shared across the pipeline."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum

import numpy as np


class Region(StrEnum):
    """Body regions (and the ring) that a photo can be classified into."""

    IRIS = "iris"
    FACE = "face"
    BEAK = "beak"
    PLUMAGE_DORSAL = "plumage_dorsal"
    PLUMAGE_VENTRAL = "plumage_ventral"
    WING = "wing"
    TAIL = "tail"
    FEET = "feet"
    RING = "ring"
    OTHER = "other"


class Spectrum(StrEnum):
    RGB = "rgb"
    NIR = "nir"
    RGB_NIR = "rgb+nir"


class Illumination(StrEnum):
    OFF = "off"
    VISIBLE = "visible"
    IR_850 = "ir_850"
    IR_940 = "ir_940"


@dataclass
class ExposureInfo:
    iso: float | None = None
    shutter_s: float | None = None
    aperture: float | None = None
    focus_distance_m: float | None = None


@dataclass
class Frame:
    """One image from any capture device. Pixels are HxW (mono) or HxWxC uint8/uint16."""

    pixels: np.ndarray
    spectrum: Spectrum
    device_id: str
    timestamp: datetime = field(default_factory=lambda: datetime.now(UTC))
    exposure: ExposureInfo = field(default_factory=ExposureInfo)
    extra: dict = field(default_factory=dict)

    @property
    def height(self) -> int:
        return int(self.pixels.shape[0])

    @property
    def width(self) -> int:
        return int(self.pixels.shape[1])
