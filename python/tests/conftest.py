import http.server
import io
import json
import struct
import threading
import zlib
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
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "xdg-state"))
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg-cache"))
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


# -- local image server ------------------------------------------------------------
def tiny_png(w: int = 8, h: int = 6, rgb=(200, 40, 40)) -> bytes:
    """A valid RGB PNG without needing Pillow."""
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def tiny_jpeg() -> bytes | None:
    try:
        from PIL import Image
    except ImportError:
        return None
    buf = io.BytesIO()
    Image.new("RGB", (8, 6), (40, 40, 200)).save(buf, "JPEG")
    return buf.getvalue()


BIG = 11 * 1024 * 1024


class _ImageHandler(http.server.BaseHTTPRequestHandler):
    files: dict = {}

    def log_message(self, *a):  # keep pytest output quiet
        pass

    def _send(self, body_too: bool):
        path = self.path.split("?", 1)[0]
        if path == "/stream-big.png":  # no Content-Length: the cap must hold while streaming
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.end_headers()
            if body_too:
                block = b"\0" * 65536
                try:
                    for _ in range(BIG // len(block) + 1):
                        self.wfile.write(block)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            return
        if path not in self.files:
            self.send_error(404)
            return
        ctype, body = self.files[path]
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body_too:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_GET(self):
        self._send(True)

    def do_HEAD(self):
        self._send(False)


@pytest.fixture(scope="session")
def image_server():
    """Base URL of a local HTTP server with /a.png, /b.jpg, /big.png (11 MB), /stream-big.png and /page.html."""
    files = {"/a.png": ("image/png", tiny_png()), "/big.png": ("image/png", b"\0" * BIG),
             "/page.html": ("text/html", b"<html>hi</html>"), "/noext": ("image/png", tiny_png())}
    jpeg = tiny_jpeg()
    if jpeg:
        files["/b.jpg"] = ("image/jpeg", jpeg)
    handler = type("H", (_ImageHandler,), {"files": files})
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield f"http://127.0.0.1:{srv.server_address[1]}"
    srv.shutdown()
