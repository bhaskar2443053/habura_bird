from pathlib import Path

import numpy as np
import pytest

from birdreid.capture import load_protocols
from birdreid.types import Frame, Spectrum

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def protocols():
    return load_protocols(ROOT / "configs" / "protocols")


def make_frame(sharp: bool = True, size: int = 800, value: int = 128) -> Frame:
    rng = np.random.default_rng(0)
    if sharp:
        pixels = rng.integers(40, 200, size=(size, size, 3), dtype=np.uint8)
    else:
        pixels = np.full((size, size, 3), value, dtype=np.uint8)
    return Frame(pixels=pixels, spectrum=Spectrum.RGB, device_id="test")


@pytest.fixture
def frame_factory():
    return make_frame
