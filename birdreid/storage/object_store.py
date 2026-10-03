"""Cloud object storage for raw captures. The iOS app uploads straight to it via presigned URLs."""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

from birdreid.types import Region, Spectrum


def image_key(
    site: str,
    session_id: str,
    region: Region,
    view: str,
    spectrum: Spectrum,
    shot_id: str,
    ext: str = "jpg",
) -> str:
    """Raw image layout: raw/{site}/{session}/{region}/{view}_{spectrum}_{shot}.{ext}.

    Keys never contain the individual ID: identity is assigned later (ring OCR / ReID / review)
    and lives in the metadata DB, so a re-identification never moves objects.
    """
    return f"raw/{site}/{session_id}/{region.value}/{view}_{spectrum.value}_{shot_id}.{ext}"


def manifest_key(site: str, session_id: str) -> str:
    return f"raw/{site}/{session_id}/session.json"


class StorageBackend(Protocol):
    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> str: ...

    def get(self, key: str) -> bytes: ...

    def exists(self, key: str) -> bool: ...

    def presigned_put_url(self, key: str, content_type: str, expires_s: int = 3600) -> str: ...


class LocalStorage:
    """Filesystem backend for development and tests."""

    def __init__(self, root: str | Path):
        self.root = Path(root)

    def _path(self, key: str) -> Path:
        path = (self.root / key).resolve()
        if not path.is_relative_to(self.root.resolve()):
            raise ValueError(f"key escapes storage root: {key}")
        return path

    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> str:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return f"file://{path}"

    def get(self, key: str) -> bytes:
        return self._path(key).read_bytes()

    def exists(self, key: str) -> bool:
        return self._path(key).exists()

    def presigned_put_url(self, key: str, content_type: str, expires_s: int = 3600) -> str:
        return f"file://{self._path(key)}"


class S3Storage:
    """AWS S3 (or any S3-compatible store such as MinIO). Needs the `s3` extra."""

    def __init__(self, bucket: str, region: str | None = None, endpoint_url: str | None = None):
        import boto3

        self.bucket = bucket
        self.client = boto3.client("s3", region_name=region, endpoint_url=endpoint_url)

    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> str:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType=content_type)
        return f"s3://{self.bucket}/{key}"

    def get(self, key: str) -> bytes:
        return self.client.get_object(Bucket=self.bucket, Key=key)["Body"].read()

    def exists(self, key: str) -> bool:
        from botocore.exceptions import ClientError

        try:
            self.client.head_object(Bucket=self.bucket, Key=key)
        except ClientError:
            return False
        return True

    def presigned_put_url(self, key: str, content_type: str, expires_s: int = 3600) -> str:
        return self.client.generate_presigned_url(
            "put_object",
            Params={"Bucket": self.bucket, "Key": key, "ContentType": content_type},
            ExpiresIn=expires_s,
        )
