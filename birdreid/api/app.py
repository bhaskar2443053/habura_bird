"""Ingest API used by the iOS app. Needs the `api` extra.

Run locally:  BIRDREID_STORAGE=./data uvicorn birdreid.api.app:app --reload
"""

from __future__ import annotations

import os
import uuid

from fastapi import FastAPI
from pydantic import BaseModel

from birdreid.storage.object_store import LocalStorage, S3Storage, StorageBackend, image_key
from birdreid.types import Region, Spectrum


def storage_from_env() -> StorageBackend:
    bucket = os.environ.get("BIRDREID_S3_BUCKET")
    if bucket:
        return S3Storage(bucket, region=os.environ.get("AWS_REGION"))
    return LocalStorage(os.environ.get("BIRDREID_STORAGE", "./data"))


class UploadRequest(BaseModel):
    site: str
    session_id: str
    region: Region
    view: str
    spectrum: Spectrum = Spectrum.RGB
    content_type: str = "image/jpeg"


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
        shot_id = uuid.uuid4().hex
        ext = "png" if req.content_type == "image/png" else "jpg"
        key = image_key(req.site, req.session_id, req.region, req.view, req.spectrum, shot_id, ext)
        return UploadTicket(
            shot_id=shot_id, key=key, url=store.presigned_put_url(key, req.content_type)
        )

    return app


app = create_app()
