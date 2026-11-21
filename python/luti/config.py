"""Profiles, shared with luti's Bash CLI.

Layout (identical on every OS):
    $XDG_CONFIG_HOME/luti/<profile>/config   key=value lines (optional double quotes)
    $XDG_CONFIG_HOME/luti/<profile>/token    raw JWT, mode 0600, directory 0700
XDG_CONFIG_HOME defaults to ~/.config. Known keys: instance, username, mfa
(true/false) and an optional api (v3/v4). Unknown keys are kept on rewrite.
The password is never stored.

If the optional `keyring` package is installed (and has a working backend),
the token goes to the keyring instead of the token file. Set LUTI_NO_KEYRING=1
to force the token file. A token file written by the Bash CLI is still read.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar

KNOWN_KEYS = ("instance", "username", "mfa", "api")
KEYRING_SERVICE = "luti"
_SAFE_VALUE = re.compile(r"^[A-Za-z0-9._:/@+%~,-]*$")
_PROFILE_NAME = re.compile(r"^[A-Za-z0-9._@-]+$")


def config_root() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return Path(base) / "luti"


def state_root() -> Path:
    """$XDG_STATE_HOME/luti (default ~/.local/state/luti), the same on every OS."""
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "luti"


def cache_root() -> Path:
    """$XDG_CACHE_HOME/luti (default ~/.cache/luti)."""
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(base) / "luti"


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    """Write via a temp file in the same directory, then os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        os.write(fd, text.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, path)


def valid_profile_name(name: str) -> bool:
    return bool(_PROFILE_NAME.match(name)) and name not in (".", "..")


def parse_config(text: str) -> dict[str, str]:
    """Parse key=value lines. Blank lines and # comments are ignored."""
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if key.startswith("export "):
            key = key[len("export "):].strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = re.sub(r'\\(["\\$`])', r"\1", value[1:-1])
        elif len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1]
        out[key] = value
    return out


def _quote(value: str) -> str:
    if _SAFE_VALUE.match(value):
        return value
    return '"' + re.sub(r'(["\\$`])', r"\\\1", value) + '"'


def format_config(values: dict[str, str]) -> str:
    keys = [k for k in KNOWN_KEYS if k in values] + [k for k in values if k not in KNOWN_KEYS]
    return "".join(f"{k}={_quote(str(values[k]))}\n" for k in keys)


@dataclass
class Profile:
    name: str
    instance: str = ""
    username: str = ""
    mfa: bool = False
    api: str | None = None  # "v3" / "v4" override, None = auto-detect
    extra: dict[str, str] = field(default_factory=dict)

    @property
    def dir(self) -> Path:
        return config_root() / self.name

    @property
    def config_file(self) -> Path:
        return self.dir / "config"

    @property
    def token_file(self) -> Path:
        return self.dir / "token"

    # -- config ---------------------------------------------------------
    @classmethod
    def load(cls, name: str) -> "Profile":
        if not valid_profile_name(name):
            raise ValueError(f"invalid profile name: {name!r}")
        p = cls(name=name)
        if p.config_file.is_file():
            values = parse_config(p.config_file.read_text(encoding="utf-8"))
            p.instance = values.pop("instance", "")
            p.username = values.pop("username", "")
            p.mfa = values.pop("mfa", "false").strip().lower() in ("true", "1", "yes", "on")
            api = values.pop("api", "").strip().lower()
            p.api = api if api in ("v3", "v4") else None
            p.extra = values
        return p

    def exists(self) -> bool:
        return self.config_file.is_file()

    def _ensure_dir(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.dir, 0o700)

    def save(self) -> None:
        self._ensure_dir()
        values: dict[str, str] = {
            "instance": self.instance,
            "username": self.username,
            "mfa": "true" if self.mfa else "false",
        }
        if self.api:
            values["api"] = self.api
        values.update({k: v for k, v in self.extra.items() if k not in KNOWN_KEYS})
        atomic_write(self.config_file, format_config(values), 0o644)

    # -- settings (extra keys; the Bash CLI ignores ones it doesn't know) --
    SETTINGS: ClassVar[dict[str, str]] = {
        "images": "auto",           # auto / on / off
        "thumbnails": "true",       # thumbnails in the feed
        "open_origin": "false",     # open the federated original (ap_id) instead of the home-instance page
        "stargaze_refresh": "300",  # seconds between background stargaze checks (0 = off)
    }

    def setting(self, key: str) -> str:
        return self.extra.get(key, self.SETTINGS.get(key, ""))

    def flag(self, key: str) -> bool:
        return self.setting(key).strip().lower() in ("true", "1", "yes", "on")

    def set_setting(self, key: str, value: str | bool | int) -> None:
        if isinstance(value, bool):
            value = "true" if value else "false"
        self.extra[key] = str(value)

    @property
    def stars_file(self) -> Path:
        return self.dir / "stars"

    @property
    def state_dir(self) -> Path:
        return state_root() / self.name

    # -- token ----------------------------------------------------------
    def read_token(self) -> str | None:
        kr = _keyring()
        if kr is not None:
            try:
                tok = kr.get_password(KEYRING_SERVICE, self.name)
                if tok:
                    return tok
            except Exception:
                pass
        if self.token_file.is_file():
            tok = self.token_file.read_text(encoding="utf-8").strip()
            return tok or None
        return None

    def write_token(self, token: str) -> None:
        self._ensure_dir()
        kr = _keyring()
        if kr is not None:
            try:
                kr.set_password(KEYRING_SERVICE, self.name, token)
                if self.token_file.exists():
                    self.token_file.unlink()
                return
            except Exception:
                pass
        fd = os.open(self.token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, token.encode())
        finally:
            os.close(fd)

    def clear_token(self) -> None:
        kr = _keyring()
        if kr is not None:
            try:
                kr.delete_password(KEYRING_SERVICE, self.name)
            except Exception:
                pass
        if self.token_file.exists():
            self.token_file.unlink()


def list_profiles() -> list[str]:
    root = config_root()
    if not root.is_dir():
        return []
    return sorted(p.name for p in root.iterdir() if (p / "config").is_file())


def _keyring():
    if os.environ.get("LUTI_NO_KEYRING"):
        return None
    try:
        import keyring  # type: ignore
        from keyring.backends import fail  # type: ignore
    except Exception:
        return None
    try:
        if isinstance(keyring.get_keyring(), fail.Keyring):
            return None
    except Exception:
        return None
    return keyring
