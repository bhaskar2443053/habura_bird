import numpy as np

from birdreid.match import Decision, FusionConfig, Gallery, fuse, open_set_decision
from birdreid.types import Region


def test_fuse_renormalises_missing_regions():
    config = FusionConfig(weights={Region.IRIS: 3.0, Region.FEET: 1.0})
    score, coverage = fuse({Region.FEET: 0.9}, config)
    assert score == 0.9 and coverage == 0.25
    score, coverage = fuse({Region.IRIS: 1.0, Region.FEET: 0.6}, config)
    assert abs(score - 0.9) < 1e-9 and coverage == 1.0


def test_gallery_reidentifies_individual():
    rng = np.random.default_rng(1)
    protos = {ind: {r: rng.normal(size=64) for r in (Region.IRIS, Region.FEET)} for ind in "ABC"}
    gallery = Gallery()
    for ind, regions in protos.items():
        for region, vec in regions.items():
            gallery.add(ind, region, vec)

    query = {r: v + rng.normal(scale=0.1, size=64) for r, v in protos["B"].items()}
    decision, ranked = open_set_decision(gallery.query(query), FusionConfig())
    assert decision == Decision.MATCH and ranked[0][0] == "B"

    stranger = {Region.IRIS: rng.normal(size=64)}
    decision, _ = open_set_decision(gallery.query(stranger), FusionConfig())
    assert decision == Decision.NEW
