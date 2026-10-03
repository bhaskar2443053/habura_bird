"""Device abstraction: every camera (iPhone, UVC NIR, file replay) implements CaptureDevice.

The iPhone app implements the same contract natively in Swift; this Python protocol is used
for server-side replay, edge rigs and tests.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable

from birdreid.types import Frame, Illumination, Spectrum


@dataclass(frozen=True)
class DeviceCapabilities:
    spectra: tuple[Spectrum, ...]
    max_resolution: tuple[int, int]  # (width, height)
    illumination: tuple[Illumination, ...] = (Illumination.OFF,)
    has_macro: bool = False
    has_depth: bool = False


@dataclass(frozen=True)
class StillRequest:
    burst: int = 1
    illumination: Illumination = Illumination.OFF
    metadata: dict = field(default_factory=dict)


@runtime_checkable
class CaptureDevice(Protocol):
    id: str
    capabilities: DeviceCapabilities

    def open(self) -> None: ...

    def stream(self) -> Iterator[Frame]:
        """Preview frames for live guidance."""
        ...

    def capture_still(self, request: StillRequest) -> list[Frame]:
        """Full-resolution capture; returns `request.burst` frames."""
        ...

    def set_illumination(self, mode: Illumination) -> None: ...

    def close(self) -> None: ...
