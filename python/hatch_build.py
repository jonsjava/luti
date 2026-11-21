"""Hatch build hook: bundle the shared endpoint map into the package.

The single source of truth is ../spec/endpoints.json in the luti repo. It is
copied into the wheel (and sdist) as luti/endpoints.json at build time, so
the repo never holds a second copy. A wheel built from an sdist finds the file
already inside the package and needs nothing extra.
"""
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class SpecBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version, build_data):
        root = Path(self.root)
        spec = root.parent / "spec" / "endpoints.json"
        if not spec.is_file():
            # Building from an sdist, which carries the file inside the package.
            # It is gitignored in the repo, so include it explicitly.
            spec = root / "luti" / "endpoints.json"
        if not spec.is_file():
            raise FileNotFoundError(f"luti build: cannot find the endpoint spec at {spec}")
        build_data["force_include"][str(spec)] = "luti/endpoints.json"
