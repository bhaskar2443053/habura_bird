"""Per-region capture protocols, loaded from configs/protocols/*.yaml."""

from __future__ import annotations

from pathlib import Path

import yaml
from pydantic import BaseModel, Field

from birdreid.types import Region, Spectrum


class ViewSpec(BaseModel):
    name: str
    hint: str = ""


class QualityThresholds(BaseModel):
    min_sharpness: float = 50.0
    max_glare_ratio: float = 0.10
    min_brightness: float = 30.0
    max_brightness: float = 225.0
    min_short_side_px: int = 256


class RegionProtocol(BaseModel):
    region: Region
    spectra: list[Spectrum] = Field(default_factory=lambda: [Spectrum.RGB])
    views: list[ViewSpec]
    min_shots_per_view: int = 1
    required: bool = True
    quality: QualityThresholds = Field(default_factory=QualityThresholds)
    guidance: str = ""


def load_protocols(folder: str | Path) -> dict[Region, RegionProtocol]:
    protocols: dict[Region, RegionProtocol] = {}
    for path in sorted(Path(folder).glob("*.yaml")):
        proto = RegionProtocol.model_validate(yaml.safe_load(path.read_text()))
        protocols[proto.region] = proto
    return protocols
