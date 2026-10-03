import numpy as np

from birdreid.ocr import RingRegistry
from birdreid.regions import RegionClassifier
from birdreid.types import Region


def test_ring_registry_matching():
    registry = RingRegistry(["HB1203", "HB1208", "HB4501"])
    assert registry.match("hb-1203").status == "exact"
    fuzzy = registry.match("HBI2O3")  # OCR confused I/1 and O/0
    assert fuzzy.status == "fuzzy" and fuzzy.code == "HB1203"
    assert registry.match("HB4502").code == "HB4501"
    assert registry.match("HB1209").status == "ambiguous"  # one edit from 1203 and 1208
    assert registry.match("ZZ9999").status == "unknown"
    assert registry.match("??").status == "invalid_format"


class FixedBackend:
    def __init__(self, probs):
        self.probs = probs

    def probabilities(self, image):
        return self.probs


def test_region_classifier_review_rules():
    image = np.zeros((4, 4, 3), dtype=np.uint8)
    clf = RegionClassifier(FixedBackend({Region.FEET: 0.9, Region.BEAK: 0.1}))
    assert not clf.classify(image, hint=Region.FEET).needs_review
    assert clf.classify(image, hint=Region.BEAK).needs_review  # disagrees with checklist step
    low = RegionClassifier(FixedBackend({Region.IRIS: 0.4, Region.FACE: 0.35}))
    label = low.classify(image)
    assert label.region == Region.IRIS and label.needs_review
