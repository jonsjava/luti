"""Load the shared endpoint map (spec/endpoints.json).

Lookup order: $LUTI_SPEC, the copy bundled into the installed package, then
the repo copy (for running from a checkout).
"""
from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

_PKG_DIR = Path(__file__).resolve().parent


def spec_path() -> Path:
    env = os.environ.get("LUTI_SPEC")
    if env:
        return Path(env).expanduser()
    bundled = _PKG_DIR / "endpoints.json"
    if bundled.is_file():
        return bundled
    repo = _PKG_DIR.parent.parent / "spec" / "endpoints.json"
    if repo.is_file():
        return repo
    raise FileNotFoundError(
        "luti: endpoint spec not found (set LUTI_SPEC or reinstall luti-tui)"
    )


@lru_cache(maxsize=4)
def _load(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def load_spec() -> dict[str, Any]:
    return _load(str(spec_path()))
