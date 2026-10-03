"""Metadata records (mirrors the Postgres schema in docs/design.md §5)."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field

from birdreid.types import Region, Spectrum


class Individual(BaseModel):
    id: str
    species: str = "Chlamydotis undulata"
    ring_code: str | None = None
    first_seen: datetime | None = None
    notes: str = ""


class ImageRecord(BaseModel):
    id: str
    session_id: str
    key: str
    region_hint: Region | None = None
    region: Region | None = None
    region_confidence: float | None = None
    view: str = ""
    spectrum: Spectrum = Spectrum.RGB
    sha256: str = ""
    needs_review: bool = False


class SessionRecord(BaseModel):
    id: str
    site: str
    device_id: str
    operator: str = ""
    started_at: datetime
    individual_id: str | None = None
    ring_read: str | None = None
    images: list[ImageRecord] = Field(default_factory=list)
