"""A capture session walks the region checklist for one bird and keeps the best shot per view."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime

from birdreid.capture.protocol import RegionProtocol
from birdreid.capture.quality import QualityReport, assess
from birdreid.types import Frame, Region


@dataclass
class Shot:
    id: str
    region: Region
    view: str
    frame: Frame
    quality: QualityReport


@dataclass
class CaptureSession:
    protocols: dict[Region, RegionProtocol]
    device_id: str
    operator: str = ""
    site: str = ""
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    started_at: datetime = field(default_factory=lambda: datetime.now(UTC))
    ring_code: str | None = None
    shots: list[Shot] = field(default_factory=list)
    skipped: dict[tuple[Region, str], str] = field(default_factory=dict)

    def add(self, region: Region, view: str, frame: Frame) -> Shot:
        proto = self.protocols[region]
        if view not in {v.name for v in proto.views}:
            raise ValueError(f"unknown view {view!r} for region {region}")
        shot = Shot(uuid.uuid4().hex, region, view, frame, assess(frame, proto.quality))
        self.shots.append(shot)
        return shot

    def skip(self, region: Region, view: str, reason: str) -> None:
        self.skipped[(region, view)] = reason

    def best(self, region: Region, view: str) -> Shot | None:
        passing = [
            s for s in self.shots if s.region == region and s.view == view and s.quality.passed
        ]
        return max(passing, key=lambda s: s.quality.score, default=None)

    def pending(self) -> list[tuple[Region, str]]:
        """Required (region, view) pairs still lacking enough passing shots and not skipped."""
        todo = []
        for region, proto in self.protocols.items():
            if not proto.required:
                continue
            for view in proto.views:
                key = (region, view.name)
                if key in self.skipped:
                    continue
                passing = sum(
                    1
                    for s in self.shots
                    if s.region == region and s.view == view.name and s.quality.passed
                )
                if passing < proto.min_shots_per_view:
                    todo.append(key)
        return todo

    @property
    def complete(self) -> bool:
        return not self.pending()

    def manifest(self) -> dict:
        """Metadata written as session.json next to the uploaded images."""
        return {
            "session_id": self.id,
            "device_id": self.device_id,
            "operator": self.operator,
            "site": self.site,
            "started_at": self.started_at.isoformat(),
            "ring_code": self.ring_code,
            "shots": [
                {
                    "shot_id": s.id,
                    "region": s.region.value,
                    "view": s.view,
                    "spectrum": s.frame.spectrum.value,
                    "captured_at": s.frame.timestamp.isoformat(),
                    "quality": {
                        "sharpness": s.quality.sharpness,
                        "glare_ratio": s.quality.glare_ratio,
                        "brightness": s.quality.brightness,
                        "failures": s.quality.failures,
                    },
                    "is_best": self.best(s.region, s.view) is s,
                }
                for s in self.shots
            ],
            "skipped": [
                {"region": r.value, "view": v, "reason": why}
                for (r, v), why in self.skipped.items()
            ],
        }
