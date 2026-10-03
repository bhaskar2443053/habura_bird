import pytest
from fastapi.testclient import TestClient

from birdreid.api.app import create_app
from birdreid.storage import LocalStorage, image_key
from birdreid.types import Region, Spectrum


def test_image_key_layout():
    key = image_key("site-a", "s1", Region.IRIS, "left_eye", Spectrum.NIR, "x1", "png")
    assert key == "raw/site-a/s1/iris/left_eye_nir_x1.png"


def test_local_storage_roundtrip_and_escape(tmp_path):
    store = LocalStorage(tmp_path)
    store.put("raw/a/b.jpg", b"data")
    assert store.exists("raw/a/b.jpg") and store.get("raw/a/b.jpg") == b"data"
    with pytest.raises(ValueError):
        store.put("../outside.jpg", b"x")


def test_upload_ticket(tmp_path):
    client = TestClient(create_app(LocalStorage(tmp_path)))
    assert client.get("/health").json() == {"ok": True}
    resp = client.post(
        "/uploads",
        json={"site": "site-a", "session_id": "s1", "region": "feet", "view": "left_dorsal"},
    )
    body = resp.json()
    assert resp.status_code == 200
    assert body["key"].startswith("raw/site-a/s1/feet/left_dorsal_rgb_")
    assert body["url"].startswith("file://")
