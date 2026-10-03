import numpy as np
from PIL import Image

from birdreid.capture import CaptureSession, QualityThresholds, assess
from birdreid.devices import CaptureDevice, FileReplayDevice, StillRequest
from birdreid.types import Region


def test_all_protocols_load(protocols):
    assert {Region.IRIS, Region.BEAK, Region.FEET, Region.RING, Region.FACE} <= set(protocols)
    assert protocols[Region.IRIS].min_shots_per_view == 2
    assert protocols[Region.WING].required is False


def test_quality_gate_flags_blur_and_size(frame_factory):
    thresholds = QualityThresholds(min_sharpness=50, min_short_side_px=256)
    assert assess(frame_factory(sharp=True), thresholds).passed
    blurry = assess(frame_factory(sharp=False), thresholds)
    assert "blurry" in blurry.failures
    small = assess(frame_factory(sharp=True, size=100), thresholds)
    assert "too_small" in small.failures


def test_session_tracks_checklist(protocols, frame_factory):
    session = CaptureSession(protocols=protocols, device_id="test", site="site-a")
    assert (Region.BEAK, "dorsal") in session.pending()
    assert (Region.WING, "left_spread") not in session.pending()  # optional region

    session.add(Region.BEAK, "dorsal", frame_factory(sharp=False))
    assert session.best(Region.BEAK, "dorsal") is None
    good = session.add(Region.BEAK, "dorsal", frame_factory(sharp=True))
    assert session.best(Region.BEAK, "dorsal") is good
    assert (Region.BEAK, "dorsal") not in session.pending()

    session.skip(Region.FEET, "left_plantar", "bird stressed")
    assert (Region.FEET, "left_plantar") not in session.pending()

    manifest = session.manifest()
    assert manifest["site"] == "site-a"
    assert [s["is_best"] for s in manifest["shots"]] == [False, True]
    assert manifest["skipped"][0]["reason"] == "bird stressed"


def test_file_replay_device(tmp_path):
    for i in range(3):
        Image.fromarray(np.full((10, 10, 3), i * 50, dtype=np.uint8)).save(tmp_path / f"{i}.png")
    device = FileReplayDevice(tmp_path)
    assert isinstance(device, CaptureDevice)
    device.open()
    frames = device.capture_still(StillRequest(burst=2))
    assert len(frames) == 2 and frames[1].pixels[0, 0, 0] == 50
    assert len(device.capture_still(StillRequest(burst=5))) == 1
    assert len(list(device.stream())) == 3
