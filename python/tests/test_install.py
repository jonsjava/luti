"""`pip install ./python` into fresh venvs, checked from outside the repo.

Slow (it downloads dependencies), so it is marked `install`; skip with `-m "not install"`.
"""
import subprocess
import sys
import venv
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.install


def _venv(path: Path) -> Path:
    venv.EnvBuilder(with_pip=True, clear=True).create(path)
    return path / ("Scripts" if sys.platform == "win32" else "bin")


def _pip_install(bin_: Path, target: str, cwd: Path) -> None:
    r = subprocess.run([str(bin_ / "python"), "-m", "pip", "install", "-q", target],
                       cwd=cwd, capture_output=True, text=True, timeout=600)
    if r.returncode and ("Could not find a version" in r.stderr or "NewConnectionError" in r.stderr):
        pytest.skip("no access to the package index")
    assert r.returncode == 0, r.stderr[-2000:]


def _py(bin_: Path, code: str, cwd: Path) -> str:
    r = subprocess.run([str(bin_ / "python"), "-c", code], cwd=cwd, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def test_core_install_has_no_tui_deps(tmp_path):
    bin_ = _venv(tmp_path / "core")
    _pip_install(bin_, str(ROOT), tmp_path)
    out = _py(bin_, "import importlib.util as u, sys, luti, luti.client, luti.spec;"
                    "print(u.find_spec('textual') is None, 'textual' in sys.modules, len(luti.spec.load()['ops']),"
                    " 'site-packages' in str(luti.spec.spec_path()))", tmp_path)
    found, loaded, ops, bundled = out.split()
    assert (found, loaded, bundled) == ("True", "False", "True") and int(ops) > 50
    r = subprocess.run([str(bin_ / "luti-tui")], cwd=tmp_path, capture_output=True, text=True, timeout=60)
    assert r.returncode == 2 and "luti[tui]" in r.stderr


def test_tui_install_runs_with_bundled_spec(tmp_path):
    bin_ = _venv(tmp_path / "tui")
    _pip_install(bin_, f"{ROOT}[tui]", tmp_path)
    r = subprocess.run([str(bin_ / "luti-tui"), "--spec-path"], cwd=tmp_path, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0 and "site-packages" in r.stdout and "ops)" in r.stdout, r.stdout + r.stderr
    _py(bin_, "import textual, textual_image, PIL, luti.tui.app", tmp_path)
