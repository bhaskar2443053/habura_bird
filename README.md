# habura_bird — houbara bustard re-identification

A framework that captures standardised multi-region photos of houbara bustards (iris, face, beak, plumage, feet, leg ring) and re-identifies individuals from them.

Full design: [docs/design.md](docs/design.md).

## What's here (M0 skeleton)

| Module | Purpose |
|---|---|
| `birdreid/devices` | `CaptureDevice` interface that every camera implements (iPhone, USB-C NIR, file replay) |
| `birdreid/capture` | Per-region protocols (`configs/protocols/*.yaml`), quality gate, capture session checklist + `session.json` manifest |
| `birdreid/regions` | Photo → region classifier (zero-shot CLIP to start; review on low confidence or checklist disagreement) |
| `birdreid/ocr` | Ring code validation against the ring registry, tolerant of common OCR confusions |
| `birdreid/embed` | Embedder interface + frozen DINOv2 baseline |
| `birdreid/match` | Per-region gallery kNN, weighted fusion with missing regions, open-set decision |
| `birdreid/storage` | Cloud object storage (S3 / local) and key layout; metadata schema |
| `birdreid/api` | Ingest API: issues presigned upload URLs to the iOS app |
| `apps/ios` | SwiftUI iPhone/iPad capture app (M1): guided checklist, live quality gate, ring OCR, offline upload queue. See [apps/ios/README.md](apps/ios/README.md) |

Not yet built: iris unwrapping and NIR-vs-RGB comparison (M2), the server-side ring OCR engine, and trained per-region models (M3).

## Develop

```bash
pip install -e ".[dev]"
pytest
ruff check . && ruff format --check .
```

Optional extras: `api` (FastAPI server), `s3` (AWS S3 backend), `ml` (CLIP / DINOv2), `ocr` (PaddleOCR).

Run the ingest API locally (stores to `./data`; set `BIRDREID_S3_BUCKET` to use S3):

```bash
pip install -e ".[api]"
uvicorn birdreid.api.app:app --reload
```
