"""Exports configs/protocols/*.yaml as JSON for the iOS app bundle.

The app has no YAML parser, so it ships this JSON instead. Re-run after editing a protocol:

    python scripts/export_protocols.py

tests/test_ios_protocols.py fails while the exported file is out of date.
"""

from __future__ import annotations

import json
from pathlib import Path

from birdreid.capture.protocol import load_protocols
from birdreid.types import Region

ROOT = Path(__file__).resolve().parents[1]
PROTOCOLS = ROOT / "configs" / "protocols"
OUTPUT = ROOT / "apps" / "ios" / "HoubaraCapture" / "Resources" / "protocols.json"

# Checklist order in the app: the ring first, since a confident read identifies the bird.
ORDER = [
    Region.RING,
    Region.FACE,
    Region.IRIS,
    Region.BEAK,
    Region.FEET,
    Region.PLUMAGE_DORSAL,
    Region.PLUMAGE_VENTRAL,
    Region.WING,
    Region.TAIL,
]


def render() -> str:
    protocols = load_protocols(PROTOCOLS)
    ordered = [protocols[r] for r in ORDER if r in protocols]
    ordered += [p for r, p in protocols.items() if r not in ORDER]
    body = {"version": 1, "regions": [p.model_dump(mode="json") for p in ordered]}
    return json.dumps(body, indent=2) + "\n"


if __name__ == "__main__":
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(render())
    print(f"wrote {OUTPUT.relative_to(ROOT)}")
