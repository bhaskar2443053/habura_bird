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
   once the shot has been steady and sharp for a few frames. Preview and still are measured on the
   same centre square (40 % of the short side), the still resampled to 512 px so a sharp 24/48 MP
   photo isn't scored blurry. Eye views also need a pupil-sized dark disc in the middle of the
   frame (at least 8 % of the short side), so a whole-head shot doesn't pass as an iris photo. Every still is assessed again, saved
   with exposure metadata, and the best passing shot of each view is marked `is_best`.
   No flash is ever fired (welfare rule for eye work). Tap to focus.
4. **Ring OCR**: on the ring step, Apple Vision reads the code live and from each ring photo, checks
   it against the site's ring registry (tolerant of O/0, I/1, S/5 … confusions, same rules as
   `birdreid.ocr.registry`), and the operator confirms or corrects it. The server re-reads the ring
   and stays authoritative.
5. **Photograph bird (free mode, the default)**: one camera screen for the whole bird. A strip of
   part pictures shows what to shoot next; each photo is sorted into a body part automatically
   (`label.source = "suggested"`) and the highlight moves on once a part has enough good shots, so
   the operator never goes back to the checklist while holding the bird. A ring code seen in a photo
   (Vision OCR) sends it to the ring, and a bundled `RegionClassifier` Core ML model, once trained,
   overrides the walk-through position when confident. A confident ring read against the registry
   is taken without a pop-up. **See, sort and share photos** afterwards shows every photo under its
   part: tap one for a full-screen viewer (swipe, pinch to zoom) where it can be moved; "Swap left/right" fixes a region whose sides were confused (`source = "operator"`) or accept all. Tapping a checklist row still opens a camera
   for just that view (`source = "checklist"`). The server re-classifies every photo regardless.
6. **Upload**: on Finish, images and then `session.json` are queued. The queue survives restarts,
   retries with back-off, and hands files to a background `URLSession`, so uploads finish even with
   the phone locked. Files go straight to S3 through presigned URLs from the ingest API; the
   manifest is uploaded last, so its presence in the bucket means the session is complete.
7. **Heat**: phones in direct sun overheat. The preview runs at 24 fps (15 when hot), the live
   quality check reads every 4th frame (every 6th when hot), hot phones take balanced rather than
   multi-frame stills, start no new uploads, and show a warning. The camera pauses after 45 s
   without a photo or tap (20 s when hot) and at the critical thermal state; one tap resumes.
8. **Export**: "Share all" on the photos screen sends a session's photos, named by ring, region and
   view (`HB1023_face_left_1.jpg`), plus `session.json` to the iOS share sheet: AirDrop, Save to
   Files or Save Images to Photos. The viewer shares or saves a single photo. The raw session
   folders are also visible in the Files app under On My iPhone > Houbara Capture.
9. **USB-C NIR camera** (iPad on iPadOS 17+, possibly iPhone on iOS 26): plugging in a UVC camera
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
