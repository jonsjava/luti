"""Version-agnostic Lemmy HTTP client driven by spec/endpoints.json.

Callers use luti's canonical request shape (the v4 field names, snake_case
enum values, and a few logical parameters):

    vote="up" | "down" | "clear"         -> score (v3) / is_upvote (v4)
    sort="top", time_range="day"         -> TopDay (v3) / sort=top&time_range_seconds=86400 (v4)
    sort/type_/listing_type snake_case   -> PascalCase on v3

`call(op, **params)` resolves `op` through the spec for the detected API
version, applies the transforms, `rename_v3` and `fixed` params, and returns
the decoded JSON body. `Pager` / `paginate` hide v3 page numbers versus v4
cursors.
"""
from __future__ import annotations

import asyncio
import logging
import re
from typing import Any, AsyncIterator

import httpx

from . import __version__
from .errors import (  # noqa: F401  (re-exported for `from luti.client import ...`)
    ApiError,
    AuthError,
    ConnectionFailed,
    LutiError,
    MfaRequired,
    NotFound,
    PermissionDenied,
    RateLimited,
    UnsupportedOp,
    UnsupportedOperation,
    VersionDetectError,
    error_for,
)
from .spec import load_spec

log = logging.getLogger("luti")

USER_AGENT = f"luti/{__version__} (+https://github.com/jonsjava/luti)"
ENUM_FIELDS = ("sort", "type_", "listing_type")

# --------------------------------------------------------------------------
# transforms
# --------------------------------------------------------------------------
def pascal_case(value: str) -> str:
    """most_comments -> MostComments. Already-Pascal values pass through."""
    if "_" not in value and value[:1].isupper():
        return value
    return "".join(part[:1].upper() + part[1:] for part in value.split("_") if part)


def snake_case(value: str) -> str:
    """MostComments -> most_comments."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", value).lower()


def transform_params(op: str, version: str, params: dict[str, Any], spec: dict | None = None) -> dict[str, Any]:
    """Turn canonical params into the wire params for `op` on `version`."""
    spec = spec or load_spec()
    entry = spec["ops"][op][version]
    tr = spec["transforms"]
    out = dict(params)

    # vote: up / down / clear
    if "vote" in out:
        rule = tr["vote"][version]
        vote = out.pop("vote")
        if vote not in ("up", "down", "clear"):
            raise ValueError(f"vote must be up, down or clear, not {vote!r}")
        out[rule["field"]] = rule[vote]
        if out[rule["field"]] is None:
            out.pop(rule["field"])  # v4 clear = is_upvote omitted (null)

    # sort=top + time range
    time_range = out.pop("time_range", None)
    ranges = tr["top_time"]["ranges"]
    if time_range is not None and time_range not in ranges:
        raise ValueError(f"unknown time range {time_range!r}")
    sort = out.get("sort")
    folds = not op.startswith("comment.")  # comment sorts have a plain Top on v3
    if version == "v3":
        if sort == "top" and folds:
            out["sort"] = ranges[time_range or "all"]["v3"]
    elif time_range is not None and sort == "top":
        seconds = ranges[time_range]["seconds"]
        if seconds is not None:
            out["time_range_seconds"] = seconds

    # enum case
    if version == "v3":
        for key in ENUM_FIELDS:
            val = out.get(key)
            if isinstance(val, str) and val:
                out[key] = pascal_case(val)

    # renames (v4 name -> v3 name)
    if version == "v3":
        for v4name, v3name in (entry.get("rename_v3") or {}).items():
            if v4name in out:
                out[v3name] = out.pop(v4name)

    out.update(entry.get("fixed") or {})
    return {k: v for k, v in out.items() if v is not None}


# --------------------------------------------------------------------------
# response helpers
# --------------------------------------------------------------------------
_SEARCH_LISTS = {"posts": "post", "comments": "comment", "communities": "community",
                 "users": "person", "persons": "person"}


def extract_items(op: str, version: str, data: Any, spec: dict | None = None) -> list[dict]:
    """Return the list of result objects in a list response.

    Multi-list responses (v3 person.content, search on both versions, the v3
    modlog) are flattened, each item tagged with `_kind`.
    """
    spec = spec or load_spec()
    if not isinstance(data, dict):
        return []
    key = (spec["ops"][op][version] or {}).get("list")
    if isinstance(key, str) and isinstance(data.get(key), list):
        return list(data[key])
    if op == "search" or isinstance(key, list):
        keys = key if isinstance(key, list) else list(_SEARCH_LISTS)
        items: list[dict] = []
        for k in keys:
            for it in data.get(k) or []:
                items.append({**it, "_kind": _SEARCH_LISTS.get(k, k.rstrip("s"))})
        return items
    if op == "modlog":
        items = []
        for k, val in data.items():
            if isinstance(val, list):
                items.extend({**it, "_kind": k} for it in val)
        items.sort(key=_modlog_when, reverse=True)
        return items
    return []


def _modlog_when(item: dict) -> str:
    for v in item.values():
        if isinstance(v, dict) and ("when_" in v or "published_at" in v):
            return v.get("when_") or v.get("published_at") or ""
    return ""


def normalize_instance(instance: str) -> str:
    instance = instance.strip()
    if not instance:
        raise ValueError("instance is empty")
    if "://" not in instance:
        instance = "https://" + instance
    return instance.rstrip("/")


def same_instance(a: str | None, b: str | None) -> bool:
    """Whether two instance URLs name the same server (a token is only valid on the server that issued it)."""
    try:
        return bool(a and b) and normalize_instance(a).lower() == normalize_instance(b).lower()
    except ValueError:
        return False


# --------------------------------------------------------------------------
# client
# --------------------------------------------------------------------------
class LemmyClient:
    """Async Lemmy client. Works on its own: no config files, no prompts.

    instance:    base URL ("lemmy.world" or "https://lemmy.world")
    token:       a JWT from an earlier login, or None
    api:         "v3" / "v4" to skip detection, or None to detect (v4 preferred)
    http_client: an httpx.AsyncClient to use (timeouts, proxies, mocking);
                 the caller keeps ownership and closes it
    """

    def __init__(
        self,
        instance: str,
        token: str | None = None,
        api: str | None = None,
        http_client: httpx.AsyncClient | None = None,
        *,
        timeout: float = 20.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ):
        if api not in (None, "v3", "v4"):
            raise ValueError("api must be v3, v4 or None")
        self.instance = normalize_instance(instance)
        self.token = token
        self.version: str | None = api
        self.site: dict | None = None
        self.spec = load_spec()
        self._owns_http = http_client is None
        self._http = http_client or httpx.AsyncClient(
            timeout=timeout,
            transport=transport,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            follow_redirects=True,
        )

    @property
    def http(self) -> httpx.AsyncClient:
        """The underlying httpx client."""
        return self._http

    async def __aenter__(self) -> "LemmyClient":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        if self._owns_http:
            await self._http.aclose()

    # -- version detection -------------------------------------------------
    async def detect(self) -> str:
        """Detect the API version (v4 preferred). Honours an explicit `api`."""
        if self.version:
            return self.version
        probe = self.spec["detect"]["probe"]
        field = self.spec["detect"]["version_field"]
        last: Exception | None = None
        for v in self.spec["detect"]["order"]:
            try:
                r = await self._http.get(f"{self.instance}/api/{v}/{probe}", headers=self._auth_headers())
            except httpx.HTTPError as e:
                raise ConnectionFailed(f"cannot reach {self.instance}: {e}") from e
            if r.status_code == 200:
                try:
                    body = r.json()
                except ValueError as e:
                    last = e
                    continue
                if isinstance(body, dict) and field in body:
                    log.debug("detected Lemmy API %s (%s) at %s", v, body.get(field), self.instance)
                    self.version = v
                    self.site = body
                    return v
            last = None
        raise VersionDetectError(
            f"{self.instance} does not look like a Lemmy 0.19+ server" + (f" ({last})" if last else "")
        )

    @property
    def server_version(self) -> str | None:
        return (self.site or {}).get("version")

    def supports(self, op: str) -> bool:
        if not self.version:
            raise LutiError("call detect() first")
        return self.spec["ops"][op][self.version] is not None

    # -- requests ------------------------------------------------------------
    def _auth_headers(self) -> dict[str, str]:
        headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
        if self.token:
            auth = self.spec["auth"]
            headers[auth["header"]] = f"{auth['scheme']} {self.token}"
        return headers

    async def call(self, op: str, **params: Any) -> Any:
        version = await self.detect()
        if op not in self.spec["ops"]:
            raise KeyError(f"unknown op {op!r}")
        entry = self.spec["ops"][op][version]
        if entry is None:
            raise UnsupportedOperation(op, version)
        wire = transform_params(op, version, params, self.spec)
        url = f"{self.instance}/api/{version}/{entry['path']}"
        method = entry["method"]
        log.debug("%s %s %s", op, method, url)
        try:
            if method == "GET":
                q = {k: (str(v).lower() if isinstance(v, bool) else v) for k, v in wire.items()}
                r = await self._http.get(url, params=q, headers=self._auth_headers())
            else:
                r = await self._http.request(method, url, json=wire, headers=self._auth_headers())
        except httpx.HTTPError as e:
            raise ConnectionFailed(f"{op}: cannot reach {self.instance}: {e}") from e
        data = self._decode(op, r)
        if op == "auth.login":
            tok = data.get(self.spec["auth"]["token_field"]) if isinstance(data, dict) else None
            if tok:
                self.token = tok
        pick = entry.get("pick")
        if pick:
            return data.get(pick) if isinstance(data, dict) else None
        return data

    def _decode(self, op: str, r: httpx.Response) -> Any:
        try:
            data = r.json() if r.content else {}
        except ValueError:
            data = None
        if isinstance(data, dict) and data.get("error"):
            raise error_for(op, r.status_code, str(data["error"]), data.get("message"))
        if r.status_code >= 400:
            text = r.text.strip()[:200] or r.reason_phrase
            raise error_for(op, r.status_code, f"http_{r.status_code}", text)
        if data is None:
            raise ApiError(op, r.status_code, "bad_json", r.text[:200])
        return data

    def items(self, op: str, data: Any) -> list[dict]:
        if not self.version:
            raise LutiError("call detect() first")
        return extract_items(op, self.version, data, self.spec)

    # -- auth convenience ----------------------------------------------------
    async def login(self, username: str, password: str, totp: str | None = None) -> str:
        params: dict[str, Any] = {"username_or_email": username, "password": password}
        if totp:
            params["totp_2fa_token"] = totp
        try:
            data = await self.call("auth.login", **params)
        except ApiError as e:
            # Lemmy issues the same JWT for two logins in the same second and
            # then trips over its own unique key (0.19: login_token_pkey in the
            # message; 1.0: a bare couldnt_create). Wait a moment, retry once.
            if "login_token_pkey" not in (e.message or "") and e.error != "couldnt_create":
                raise
            await asyncio.sleep(1.1)
            data = await self.call("auth.login", **params)
        tok = data.get("jwt") if isinstance(data, dict) else None
        if not tok:
            if isinstance(data, dict) and data.get("registration_created"):
                raise AuthError("auth.login", 200, "registration_pending", "registration is awaiting approval")
            if isinstance(data, dict) and data.get("verify_email_sent"):
                raise AuthError("auth.login", 200, "email_not_verified", "verify your email first")
            raise AuthError("auth.login", 200, "no_token", "login returned no token")
        self.token = tok
        return tok

    # -- pagination ------------------------------------------------------------
    def pager(self, op: str, limit: int = 20, **params: Any) -> "Pager":
        return Pager(self, op, limit, params)

    async def paginate(self, op: str, limit: int = 20, max_items: int | None = None, **params: Any) -> AsyncIterator[dict]:
        """Yield every item of a list op across pages (v3 pages or v4 cursors)."""
        pager = self.pager(op, limit, **params)
        count = 0
        while pager.has_more:
            for item in await pager.next_page():
                yield item
                count += 1
                if max_items is not None and count >= max_items:
                    return


class Pager:
    """Fetch a list op one page at a time, whatever the API version."""

    def __init__(self, client: LemmyClient, op: str, limit: int, params: dict[str, Any]):
        self.client = client
        self.op = op
        self.limit = limit
        self.params = params
        self.has_more = True
        self.page = 0  # v3: last page number fetched
        self.cursor: str | None = None  # v4: next_page cursor
        self.last_response: Any = None

    async def next_page(self) -> list[dict]:
        if not self.has_more:
            return []
        version = await self.client.detect()
        rule = self.client.spec["transforms"]["pagination"][version]
        params = dict(self.params)
        if self.limit:
            params["limit"] = self.limit
        if version == "v3":
            self.page = self.page + 1 if self.page else rule["start"]
            params[rule["request"]] = self.page
        elif self.cursor:
            params[rule["request"]] = self.cursor
        data = await self.client.call(self.op, **params)
        self.last_response = data
        items = self.client.items(self.op, data)
        if version == "v3":
            self.has_more = bool(items) and (not self.limit or len(items) >= self.limit)
        else:
            nxt = data.get(rule["next_field"]) if isinstance(data, dict) else None
            if not items or not nxt or nxt == self.cursor:
                self.has_more = False
            self.cursor = nxt
        return items
