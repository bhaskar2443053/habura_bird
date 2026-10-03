# Houbara Capture (iOS)

Native SwiftUI app for M1 of the [design](../../docs/design.md): guided multi-region capture of one
bird per session, an on-device quality gate, ring OCR, and offline-first upload to cloud storage.

## What it does

1. **New bird session**: site, operator, situation (in hand / aviary / free), optional notes and a
   coarse GPS fix.
2. **Checklist** from `configs/protocols/*.yaml` (bundled as `HoubaraCapture/Resources/protocols.json`):
   leg ring first, then face, iris, beak, feet, plumage and (optional) wing. Each view shows how many
   good shots it has against the protocol's minimum. Views can be skipped with a reason; finishing
   early records the rest as "not captured".
3. **Capture screen**: live preview with a guide shape (a circle for the eye), a live quality chip
   (sharpness, glare, brightness, the same checks as `birdreid.capture.quality`) and **auto-capture**
   once the shot has been steady and sharp for a few frames. Every still is assessed again, saved
   with exposure metadata, and the best passing shot of each view is marked `is_best`.
   No flash is ever fired (welfare rule for eye work). Tap to focus.
4. **Ring OCR**: on the ring step, Apple Vision reads the code live and from each ring photo, checks
   it against the site's ring registry (tolerant of O/0, I/1, S/5 … confusions, same rules as
   `birdreid.ocr.registry`), and the operator confirms or corrects it. The server re-reads the ring
   and stays authoritative.
5. **Region labels**: every photo is labelled with the checklist step it was taken in; "Extra photos"
   are left unlabelled for the server's classifier. If a Core ML model named `RegionClassifier` is
   added to the target, the app also classifies each photo on-device and warns when a photo doesn't
   look like the region being captured.
6. **Upload**: on Finish, images and then `session.json` are queued. The queue survives restarts,
   retries with back-off, and hands files to a background `URLSession`, so uploads finish even with
   the phone locked. Files go straight to S3 through presigned URLs from the ingest API; the
   manifest is uploaded last, so its presence in the bucket means the session is complete.
7. **USB-C NIR camera** (iPad on iPadOS 17+, possibly iPhone on iOS 26): plugging in a UVC camera
   switches to it automatically, and the operator marks shots as Near-IR or Visible.

Object keys match the server: `raw/{site}/{session_id}/{region}/{view}_{spectrum}_{shot_id}.jpg`
plus `raw/{site}/{session_id}/session.json`.

## Layout

| Path | Contents |
|---|---|
| `Packages/CaptureKit` | Platform-independent core: protocol model, quality gate, session + manifest, ring registry, upload queue, ingest client. Tested with `swift test` (runs on Linux too). |
| `HoubaraCapture/Camera` | AVFoundation capture (photo + live analysis), preview, pixel conversion |
| `HoubaraCapture/Vision` | Ring OCR (Vision) and the optional Core ML region classifier |
| `HoubaraCapture/Storage`, `Upload` | Sessions on disk (Documents/Sessions, visible in Files) and the background uploader |
| `HoubaraCapture/Views` | SwiftUI screens |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated, not committed |

## Build and run

Needs a Mac with Xcode 16 or later.

```bash
brew install xcodegen
cd apps/ios
xcodegen                     # writes HoubaraCapture.xcodeproj
open HoubaraCapture.xcodeproj
```

Pick your team under Signing & Capabilities, plug in an iPhone and run. The camera doesn't work in
the simulator.

Core tests: `cd apps/ios/Packages/CaptureKit && swift test`.

If you edit a protocol YAML, re-export the bundled copy: `python scripts/export_protocols.py`
(a Python test fails while it is stale).

## Connecting to storage

Run the ingest API (see the top-level README) against your bucket:

```bash
BIRDREID_S3_BUCKET=houbara-raw AWS_REGION=me-central-1 uvicorn birdreid.api.app:app --host 0.0.0.0
```

For local testing, MinIO works too: set `BIRDREID_S3_ENDPOINT=http://<mac-ip>:9000`.
Then enter the API address and the site name in the app's Settings, and load the ring registry
(paste codes or import a CSV). Without a server address the app still captures; everything waits
on the phone.

## Known limits

- Quality thresholds come from the protocol YAMLs and are first guesses. The phone measures a
  full-resolution centre crop, so values differ somewhat from the server's whole-image numbers;
  tune them on real captures during the data-collection phase.
- The ingest API has no authentication yet. The optional API key is sent as a bearer token for when
  it sits behind a gateway.
- No on-device region model is bundled until one has been trained (design §6.1).
