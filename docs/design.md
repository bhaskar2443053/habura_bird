# Houbara ReID Capture Framework — Design v0.2

Status: draft for review · updated 2026-10-03 · repo `bhaskar2443053/habura_bird` (empty)

## 0. Decisions (from bhaskar, 2026-10-03)

| Topic | Decision |
|---|---|
| Species | Houbara bustard (single species; detectors and models are trained for it) |
| Capture context | Breeding sites and captive birds, so bird-in-hand / close-range capture is realistic for iris, beak and feet |
| Capture device | **iPhone first** (native iOS app); Android and other devices later via the same device interface |
| IR | Recommended setup below (§3.3); visible-light iris capture is tried first because houbara irises are light-coloured |
| Existing data | None; collection starts from scratch, so the first months are a data-collection phase |
| Storage | Captured data uploads to cloud object storage (default: AWS S3, pluggable for GCS/Azure) |
| Rings / tags | Readable leg rings / tags are OCR'd and used as ground-truth IDs |
| Classification | Every photo is automatically classified into its region (iris, beak, face, plumage, feet, ring, …) |


## 1. Goal

Capture standardized, multi-region images of individual birds (iris, beak, face, plumage, feet, …) from either a **phone camera** or a **dedicated IR / NIR camera**, and turn them into a gallery that supports **re-identifying the same individual** later (re-capture, ringing studies, aviaries, field stations).

Design principles:

- **Device-agnostic**: every capture source implements one interface; the pipeline never knows whether pixels came from a phone or an IR rig.
- **Region-first**: a "capture" is a *session* of several *region shots*, each with its own quality gate, protocol and embedding model.
- **Partial evidence is normal**: a feet-only or iris-only sighting must still produce a ranked match. Fusion handles missing regions.
- **Provenance always**: every image keeps device, spectrum, lighting, operator and calibration metadata so models can be retrained and audited.

## 2. System overview

```
 ┌──────────────┐   ┌────────────────┐   ┌──────────────┐   ┌───────────────┐   ┌──────────────┐
 │ Capture      │──▶│ Guided capture │──▶│ Detect &     │──▶│ Per-region    │──▶│ Gallery      │
 │ devices      │   │ session (app)  │   │ crop regions │   │ embeddings    │   │ match + fuse │
 │ phone / IR   │   │ + quality gate │   │ + keypoints  │   │ (one model    │   │ → candidates │
 └──────────────┘   └────────────────┘   └──────────────┘   │  per region)  │   └──────┬───────┘
        ▲                   │                                └───────────────┘          │
        │                   ▼                                                           ▼
   calibration        raw store (object store, immutable)               human review / confirm ID
                      + metadata DB                                      → gallery update
```

Layers:

| Layer | Responsibility | Runs on |
|---|---|---|
| Device adapters | Uniform frame/still acquisition, exposure, IR illuminator control | phone app / edge box (Jetson, RPi) |
| Capture session | Region checklist, live guidance overlay, quality gate, retakes | phone app / edge box |
| Ingest | Upload, dedupe, store raw + metadata | server |
| Region pipeline | Detection, keypoints, alignment, crop, normalization | server (GPU) or on-device lite |
| Embedding | Per-region ReID encoders | server (GPU) |
| Matching | Per-region kNN, score fusion, open-set decision | server |
| Review UI | Confirm/reject matches, assign new IDs, label | web |

## 3. Capture device abstraction

### 3.1 Interface

```python
class CaptureDevice(Protocol):
    id: str
    capabilities: DeviceCapabilities   # spectra, resolution, min focus, has_illuminator, has_macro, fps

    def open(self, config: DeviceConfig) -> None: ...
    def stream(self) -> Iterator[Frame]: ...          # preview frames for live guidance
    def capture_still(self, req: StillRequest) -> Frame: ...  # full-res, optional burst / bracketing
    def set_illumination(self, mode: Illumination) -> None: ...  # off | visible | ir_850 | ir_940 | ring
    def calibration(self) -> Calibration: ...         # intrinsics, colour/IR response, px-per-mm at focus
    def close(self) -> None: ...

@dataclass
class Frame:
    pixels: np.ndarray            # HxWxC, uint8/uint16
    spectrum: Literal["rgb", "nir", "rgb+nir"]
    timestamp: datetime
    exposure: ExposureInfo        # iso/gain, shutter, aperture, focus distance
    device_id: str
    extra: dict                   # depth map, LiDAR scale, IMU, etc. when available
```

### 3.2 Adapters

| Adapter | Use | Notes |
|---|---|---|
| `PhoneCameraDevice` | Field use, low cost | Native app (Android CameraX / iOS AVFoundation) or Flutter; RAW/HEIF where possible; uses macro lens + LiDAR/depth for scale when present; on-device lightweight detector for guidance |
| `IRCameraDevice` | Iris and low-light; avoids startling the bird | NIR monochrome sensor (e.g. USB3/GigE industrial cam, 850/940 nm ring illuminator, IR-pass filter); controlled via Aravis/GenICam or V4L2; ideal for iris texture since NIR reduces pigment glare |
| `DualSpectrumRig` | Lab / ringing station | Synchronized RGB + NIR pair on a fixed handling cradle; calibrated geometry so crops map across spectra |
| `FileReplayDevice` | Tests, bulk import of existing photo archives | Reads folders/video and emits Frames with supplied metadata |

New hardware = new adapter only; nothing downstream changes.

### 3.3 IR options for iPhone / iPad (recommendation)

- **The iPhone's built-in IR (Face ID / TrueDepth) cannot be used.** Apple only exposes depth data from it, not raw IR images, and it faces the user. The rear cameras have IR-cut filters, so clip-on IR filters don't help.
- **Thermal add-ons (FLIR ONE, Topdon, InfiRay) are the wrong tool.** They are long-wave thermal, which shows heat rather than iris texture, and their resolution is too low.
- **Recommended: a USB-C UVC near-IR camera with an 850 nm LED ring.** Use a NoIR / IR-pass module (e.g. Arducam or ELP USB NIR macro) at ≥5 MP with a fixed or manual focus macro lens. iPadOS 17+ officially supports external UVC cameras through AVFoundation ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10106)), so an **iPad with USB-C plus this camera** is the safe path. Reports suggest iOS 26 adds UVC support on USB-C iPhones as well ([video](https://www.youtube.com/watch?v=iuWiISt7H5g)), but this is not verified yet; test on one iPhone 15/16/17 before buying more.
- **Fallback:** a standalone handheld NIR camera (e.g. a full-spectrum-converted compact with an 850 nm filter) that uploads over Wi-Fi into the same session.
- **Start with visible light.** Houbara irises are pale, so an iPhone macro lens with diffused light may already capture enough texture. Phase M2 compares RGB and NIR iris matching before standardising on hardware.

### 3.4 Calibration

Each device stores a calibration record: intrinsics, colour checker / IR reflectance target response, and **px-per-mm** at working distance (scale bar or depth). Scale matters for feet (scale size, claw length) and for normalizing iris crops.

## 4. Capture protocol (per region)

A session is driven by a **region checklist**. Each region has a protocol spec (YAML), so protocols can change without code changes.

| Region | Preferred spectrum | Views | Key quality checks | Identity signal |
|---|---|---|---|---|
| Iris / eye | NIR (fallback RGB macro) | frontal to eye, 1–3 shots | sharpness (Laplacian var), specular glare ratio, pupil/iris segmentation confidence, iris radius ≥ N px | iris texture, pigment flecks |
| Face / head | RGB | left & right lateral, frontal | pose (yaw within ±15° of target), sharpness, occlusion | facial markings, eye-ring, feather patterns |
| Beak | RGB (+NIR optional) | left & right lateral, dorsal | full beak in frame, scale available | shape, nicks, wear, colouration |
| Plumage | RGB | dorsal, ventral, left & right wing spread, tail | coverage %, motion blur, white balance (colour card) | spot/bar patterns, moult state (note: changes seasonally) |
| Feet / legs | RGB macro | left & right, plantar + dorsal | scale bar present, focus on scutes | scute arrangement, scars, rings/bands |
| Ring / tag | RGB | close-up of the ring, rotate for full code | OCR confidence, all characters visible | **ground-truth individual ID** (see §6.2) |

Each region spec:

```yaml
region: iris
spectra: [nir, rgb]
views:
  - name: left_eye
  - name: right_eye
min_shots_per_view: 2
quality:
  min_sharpness: 120
  max_glare_ratio: 0.05
  min_iris_radius_px: 80
  min_seg_confidence: 0.8
guidance:
  overlay: circle_target
  hint: "Fill the circle with the eye, keep IR ring on"
```

Session flow: select bird context (species, location, handler) → app walks the checklist → live preview shows overlay + green/red quality → auto-capture burst when the gate passes → best frame kept, others retained as alternates → missing regions are allowed but recorded as `skipped` with a reason.

Animal welfare: target total handling time per session, IR preferred for eye work, no flash at eye in visible spectrum; the protocol should allow aborting at any point and still saving what was captured.

## 5. Data schema

Raw images upload from the iPhone app straight to **cloud object storage** (default AWS S3, behind a `StorageBackend` interface so GCS/Azure work too). The app uses pre-signed URLs and a resumable background upload queue, because breeding sites may have poor connectivity, so captures are saved locally first and synced later. Metadata is stored in Postgres (with `pgvector` for embeddings at this scale), and an upload event (S3 → queue) triggers the processing pipeline.

```
Individual(id, species, first_seen, ring_code?, status, notes)
Session(id, individual_id?, device_id, operator, location(geo), captured_at, context{handling|free|aviary}, protocol_version)
Device(id, kind, model, capabilities json, calibration_id)
Calibration(id, device_id, px_per_mm, intrinsics json, spectral_profile json, created_at)
Image(id, session_id, region, view, spectrum, uri, sha256, width, height, exposure json, quality json, is_best)
RegionCrop(id, image_id, region, bbox, keypoints json, mask_uri?, aligned_uri, scale_px_per_mm, quality_score)
Embedding(id, crop_id, model_name, model_version, vector vector(D))
MatchResult(id, query_session_id, candidate_individual_id, per_region_scores json, fused_score, decision, reviewer?, decided_at)
```

Folder layout for raw export / datasets:

```
data/{species}/{individual_id|unknown}/{session_id}/{region}/{view}_{spectrum}_{n}.{png|dng}
  + session.json (all metadata above)
```

## 6. Detection and cropping

1. **Bird detection**: general detector (YOLO-family / RT-DETR) fine-tuned on bird-in-hand and perched images.
2. **Region localization**: one multi-class detector for {eye, head, beak, wing, tail, body, foot, ring} plus a **keypoint model** (eye centre, beak tip, beak base, nape, wing tips, toe tips).
3. **Region-specific refinement**:
   - Iris: segment pupil + iris (U-Net / SAM-style prompt from eye box), unwrap to a normalized polar strip (Daugman rubber-sheet) so texture is pose-invariant.
   - Face/beak: align to canonical pose using keypoints (similarity transform), left/right kept separate.
   - Plumage: segment bird vs background; optional pattern-region mask; flatten/normalize colour via colour card.
   - Feet: crop per foot, rescale to fixed px-per-mm.
4. Output: `RegionCrop` with aligned image, mask, keypoints and a quality score.

On-device (phone) runs only a small detector + quality checks for guidance; full pipeline runs server-side.

### 6.1 Automatic region classification

Every uploaded photo is classified into `iris | eye | face | beak | plumage_dorsal | plumage_ventral | wing | tail | feet | ring | other/reject`:
- The app proposes a label from the checklist step it was taken in. The server **always re-classifies**, because handlers will also take ad-hoc photos.
- Model: an image classifier (e.g. a fine-tuned DINOv2/ConvNeXt head) plus the region detector (step 2 above). One photo can yield several crops (e.g. a head shot gives face + beak + eye).
- Bootstrapping with no data: start with zero-shot labels (CLIP/SigLIP prompts such as "close-up of a bird's eye"), then reviewers correct them in the review UI, and the classifier is fine-tuned once a few hundred labelled photos exist.
- Low-confidence or disagreeing labels go to a review queue.

### 6.2 Ring / tag OCR

- Detect the ring, crop it, unwrap the curved band (cylinder rectification), then run OCR (PaddleOCR or Apple Vision on-device for instant feedback, with the server result kept as authoritative).
- Codes are validated against the site's ring registry (format regex + known list). Partial reads are matched with edit distance.
- A confident ring read **links the session to an Individual automatically**. This is the main source of training labels for the ReID models, since no labelled data exists yet.
- Conflicts (ring says A, ReID strongly says B) are flagged for review, because they may be a misread or a re-ringed bird.

## 7. Per-region ReID embeddings

One encoder per region (different textures need different inductive biases):

| Region | Backbone suggestion | Training |
|---|---|---|
| Iris | small CNN/ViT on unwrapped strips (or classical Gabor iris codes as baseline) | metric learning (ArcFace / triplet) |
| Face, beak | ViT-S / ConvNeXt-T, start from DINOv2 or MegaDescriptor (wildlife ReID foundation model) | ArcFace, left/right as separate classes or flip-aware |
| Plumage | same as above + local feature matching (SuperPoint/LightGlue or ALIKED) re-ranking for pattern spots | ArcFace + geometric verification |
| Feet | CNN on scale-normalized crops + local feature re-ranking | triplet |

Baseline before any training: frozen **DINOv2 / MegaDescriptor** embeddings + cosine kNN per region. This gives a working system on day one and a benchmark to beat.

Every embedding stores `model_name@version`; re-embedding the gallery is a batch job when models change.

## 8. Gallery matching and fusion

1. For a query session, embed every available region crop.
2. Per region: kNN against gallery embeddings of the same region/view/spectrum → per-individual score (max or mean over that individual's crops).
3. **Fusion** across regions:
   - v0: weighted sum of calibrated scores, weights per region learned from validation (iris and feet likely highest, plumage lower due to moult).
   - Missing regions drop out and weights renormalize; confidence is reduced accordingly.
   - v1: learned fusion (logistic regression / small MLP over per-region scores + quality scores).
4. **Open-set decision**: if fused score < threshold τ → "likely new individual"; between τ and τ_high → human review; above τ_high → auto-suggest match (still confirmable).
5. Optional geometric re-ranking of top-k with local feature matching.
6. Confirmed matches add the session's crops to that individual's gallery.

Evaluation: CMC (rank-1/5), mAP, and open-set metrics (TPR at fixed FPR) per region and fused, split by species and by time gap between captures.

## 9. Proposed code skeleton

```
habura_bird/
  README.md
  pyproject.toml
  configs/
    protocols/{iris,face,beak,plumage,feet}.yaml
    devices/{phone,ir_cam,dual_rig}.yaml
  birdreid/
    devices/      base.py, phone.py, ir_camera.py, dual_rig.py, file_replay.py
    capture/      session.py, protocol.py, quality.py, guidance.py
    regions/      classifier.py, detector.py, keypoints.py, iris.py, align.py, crop.py
    ocr/          ring_detect.py, unwrap.py, ocr.py, registry.py
    embed/        base.py, dino_baseline.py, region_models.py
    match/        gallery.py, fusion.py, openset.py, rerank.py
    storage/      models.py (SQLAlchemy), object_store.py (S3/GCS/local), export.py
    api/          FastAPI app: ingest, match, review endpoints
  apps/
    ios/          SwiftUI capture app (AVFoundation, UVC external camera, offline upload queue)
    review_ui/    web review & labelling
  scripts/        import_archive.py, reembed_gallery.py, evaluate.py
  tests/
```

Stack defaults: Python 3.11, PyTorch, FastAPI, Postgres + pgvector, AWS S3 (MinIO locally); SwiftUI for the iPhone app.

## 10. Phased plan (houbara)

1. **M0 – Skeleton**: device interface + `FileReplayDevice`, protocol YAMLs, schema, S3 storage backend, upload ingest, zero-shot region classifier, ring OCR, DINOv2 baseline matching.
2. **M1 – iPhone capture app** (SwiftUI + AVFoundation): guided checklist, on-device quality gate, offline queue, background upload to S3. This phase also starts the **data-collection** period, in which ring IDs provide the labels.
3. **M2 – IR**: test UVC NIR camera on iPad (and iPhone on iOS 26), add `UVCExternalCameraDevice`, iris segmentation + unwrap, and compare RGB vs NIR iris matching.
4. **M3 – Trained models**: fine-tune the region classifier, then per-region metric learning once ~50+ ringed individuals have repeat captures; learned fusion; review UI.

## 11. Open questions

1. Which cloud: AWS, Google Cloud or Azure? (default AWS S3)
2. What is the ring/tag code format? Is there an existing ring registry to validate against?
3. Roughly how many birds and sessions per season? This determines storage size and when trained models become viable.
