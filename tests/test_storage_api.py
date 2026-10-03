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


def test_upload_ticket_uses_client_shot_id(tmp_path):
    client = TestClient(create_app(LocalStorage(tmp_path)))
    shot_id = "0123456789abcdef0123456789abcdef"
    body = client.post(
        "/uploads",
        json={
            "site": "site-a",
            "session_id": "s1",
            "region": "iris",
            "view": "left_eye",
            "spectrum": "nir",
            "shot_id": shot_id,
        },
    ).json()
    assert body["shot_id"] == shot_id
    assert body["key"] == f"raw/site-a/s1/iris/left_eye_nir_{shot_id}.jpg"


@pytest.mark.parametrize(
    "override",
    [{"site": "../etc"}, {"session_id": "a/b"}, {"view": ""}, {"shot_id": "NOT-HEX"}],
)
def test_upload_ticket_rejects_unsafe_segments(tmp_path, override):
    client = TestClient(create_app(LocalStorage(tmp_path)))
    payload = {"site": "site-a", "session_id": "s1", "region": "feet", "view": "left_dorsal"}
    assert client.post("/uploads", json=payload | override).status_code == 422


def test_manifest_ticket(tmp_path):
    client = TestClient(create_app(LocalStorage(tmp_path)))
    body = client.post("/manifests", json={"site": "site-a", "session_id": "s1"}).json()
    assert body["key"] == "raw/site-a/s1/session.json"
    assert body["url"].startswith("file://")
