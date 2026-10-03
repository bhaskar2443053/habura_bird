"""Ingest API used by the iOS app. Needs the `api` extra.

Run locally:  BIRDREID_STORAGE=./data uvicorn birdreid.api.app:app --reload
"""

from __future__ import annotations

import os
import uuid

from fastapi import FastAPI
from pydantic import BaseModel, Field

from birdreid.storage.object_store import (
    LocalStorage,
    S3Storage,
    StorageBackend,
    image_key,
    manifest_key,
)
from birdreid.types import Region, Spectrum


def storage_from_env() -> StorageBackend:
    bucket = os.environ.get("BIRDREID_S3_BUCKET")
    if bucket:
        return S3Storage(
            bucket,
            region=os.environ.get("AWS_REGION"),
            endpoint_url=os.environ.get("BIRDREID_S3_ENDPOINT"),  # e.g. MinIO for local testing
        )
    return LocalStorage(os.environ.get("BIRDREID_STORAGE", "./data"))


# Path segments of object keys: user-typed site names must not be able to change the layout.
SEGMENT = r"^[A-Za-z0-9_-]{1,64}$"
SHOT_ID = r"^[0-9a-f]{32}$"


class UploadRequest(BaseModel):
    site: str = Field(pattern=SEGMENT)
    session_id: str = Field(pattern=SEGMENT)
    region: Region
    view: str = Field(pattern=SEGMENT)
    spectrum: Spectrum = Spectrum.RGB
    content_type: str = "image/jpeg"
    # The app names shots itself so the key it writes into session.json is known before upload
    # and a retried upload overwrites the same object instead of creating a duplicate.
    shot_id: str | None = Field(default=None, pattern=SHOT_ID)


class ManifestRequest(BaseModel):
    site: str = Field(pattern=SEGMENT)
    session_id: str = Field(pattern=SEGMENT)


class UploadTicket(BaseModel):
    shot_id: str
    key: str
    url: str


def create_app(storage: StorageBackend | None = None) -> FastAPI:
    app = FastAPI(title="Houbara ReID ingest")
    store = storage or storage_from_env()

    @app.get("/health")
    def health() -> dict:
        return {"ok": True}

    @app.post("/uploads", response_model=UploadTicket)
    def request_upload(req: UploadRequest) -> UploadTicket:
        """Returns a presigned URL; the app PUTs the image there directly."""
        shot_id = req.shot_id or uuid.uuid4().hex
        ext = "png" if req.content_type == "image/png" else "jpg"
        key = image_key(req.site, req.session_id, req.region, req.view, req.spectrum, shot_id, ext)
        return UploadTicket(
            shot_id=shot_id, key=key, url=store.presigned_put_url(key, req.content_type)
        )

    @app.post("/manifests", response_model=UploadTicket)
    def request_manifest_upload(req: ManifestRequest) -> UploadTicket:
        """Presigned URL for session.json. The app uploads it last, after every image."""
        key = manifest_key(req.site, req.session_id)
        return UploadTicket(
            shot_id="", key=key, url=store.presigned_put_url(key, "application/json")
        )

    return app


app = create_app()
