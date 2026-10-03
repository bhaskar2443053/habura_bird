"""Replays images from disk as if they came from a camera (tests, archive import)."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import numpy as np
from PIL import Image

from birdreid.devices.base import DeviceCapabilities, StillRequest
from birdreid.types import Frame, Illumination, Spectrum

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp"}


class FileReplayDevice:
    def __init__(self, folder: str | Path, spectrum: Spectrum = Spectrum.RGB, device_id: str = ""):
        self.folder = Path(folder)
        self.spectrum = spectrum
        self.id = device_id or f"replay:{self.folder.name}"
        self.capabilities = DeviceCapabilities(spectra=(spectrum,), max_resolution=(0, 0))
        self._paths: list[Path] = []
        self._cursor = 0

    def open(self) -> None:
        self._paths = sorted(p for p in self.folder.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES)
        self._cursor = 0

    def _load(self, path: Path) -> Frame:
        with Image.open(path) as img:
            mode = "L" if self.spectrum == Spectrum.NIR else "RGB"
            pixels = np.asarray(img.convert(mode))
        return Frame(
            pixels=pixels, spectrum=self.spectrum, device_id=self.id, extra={"path": str(path)}
        )

    def stream(self) -> Iterator[Frame]:
        for path in self._paths:
            yield self._load(path)

    def capture_still(self, request: StillRequest) -> list[Frame]:
        frames = []
        for _ in range(request.burst):
            if self._cursor >= len(self._paths):
                break
            frames.append(self._load(self._paths[self._cursor]))
            self._cursor += 1
        return frames

    def set_illumination(self, mode: Illumination) -> None:
        pass

    def close(self) -> None:
        self._paths = []
