import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _export_module():
    spec = importlib.util.spec_from_file_location(
        "export_protocols", ROOT / "scripts" / "export_protocols.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_ios_protocols_json_is_up_to_date():
    module = _export_module()
    assert module.OUTPUT.read_text() == module.render(), (
        "apps/ios protocols.json is stale; run: python scripts/export_protocols.py"
    )
