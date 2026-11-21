import json
import os
import secrets
from pathlib import Path

import httpx
import pytest

FIXTURES = Path(__file__).parent / "fixtures"

SERVERS = {
    "v3": os.environ.get("LUTI_TEST_V3", "http://localhost:8536"),
    "v4": os.environ.get("LUTI_TEST_V4", "http://localhost:8537"),
}
ADMIN = ("luti_admin", "luti-dev-admin-pw")
USER_PW = "luti-dev-user-pw"


def fx(name: str):
    """Load a captured API response from tests/fixtures."""
    return json.loads((FIXTURES / f"{name}.json").read_text())


@pytest.fixture(autouse=True)
def isolated_config(tmp_path, monkeypatch):
    """Every test gets its own XDG config dir and never touches the keyring."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    monkeypatch.setenv("LUTI_NO_KEYRING", "1")
    monkeypatch.delenv("LUTI_PROFILE", raising=False)
    return tmp_path / "xdg"


_reachable: dict[str, bool] = {}


def server_up(version: str) -> bool:
    if version not in _reachable:
        try:
            r = httpx.get(f"{SERVERS[version]}/api/{version}/site", timeout=3)
            _reachable[version] = r.status_code == 200 and "version" in r.json()
        except Exception:
            _reachable[version] = False
    return _reachable[version]


@pytest.fixture(params=["v3", "v4"])
def server(request):
    """(version, base_url) for each dev server; skips when it is not running."""
    version = request.param
    if not server_up(version):
        pytest.skip(f"dev Lemmy {version} server not reachable at {SERVERS[version]}")
    return version, SERVERS[version]


def unique(prefix: str = "lt") -> str:
    return f"{prefix}{secrets.token_hex(4)}"


def register_user(version: str, base: str, username: str, password: str = USER_PW) -> None:
    """Register a throwaway account (registration isn't a luti op)."""
    path = "user/register" if version == "v3" else "account/auth/register"
    r = httpx.post(f"{base}/api/{version}/{path}", json={
        "username": username, "password": password, "password_verify": password,
        "answer": "luti-tui integration test"}, timeout=20)
    assert r.status_code == 200, r.text
