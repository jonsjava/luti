"""Media helpers for posts: classify links, probe content types, fetch images safely.

Core (httpx only). Image bytes are untrusted: callers should decode them with a
hardened decoder (Pillow) and never execute or open them otherwise.
"""
from __future__ import annotations

import logging
from posixpath import splitext
from urllib.parse import urlparse

import httpx

log = logging.getLogger("luti")

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".avif", ".svg", ".tiff", ".tif"}
VIDEO_EXTENSIONS = {".mp4", ".webm", ".mov", ".m4v", ".mkv", ".ogv", ".gifv"}
MAX_IMAGE_BYTES = 10 * 1024 * 1024
MEDIA_KINDS = ("image", "video", "link", "none")


class MediaTooLarge(Exception):
    """The download exceeded the size cap."""


class NotAnImage(Exception):
    """The server did not return an image."""


def is_web_url(url: str | None) -> bool:
    """True only for absolute http:// or https:// URLs with a host."""
    if not url or not isinstance(url, str):
        return False
    try:
        parts = urlparse(url.strip())
    except ValueError:
        return False
    return parts.scheme in ("http", "https") and bool(parts.netloc)


def kind_from_content_type(content_type: str | None) -> str | None:
    if not content_type:
        return None
    main = content_type.split(";")[0].strip().lower()
    if main.startswith("image/"):
        return "image"
    if main.startswith("video/"):
        return "video"
    return "link"


def kind_from_extension(url: str | None) -> str | None:
    if not is_web_url(url):
        return None
    ext = splitext(urlparse(url).path)[1].lower()  # type: ignore[arg-type]
    if ext in IMAGE_EXTENSIONS:
        return "image"
    if ext in VIDEO_EXTENSIONS:
        return "video"
    return None


def media_kind(url: str | None, content_type: str | None = None, embed_video_url: str | None = None) -> str:
    """image / video / link / none from what the server told us, then the extension.

    No network access; see `probe_kind` for the HEAD-request fallback.
    """
    if not url and not embed_video_url:
        return "none"
    kind = kind_from_content_type(content_type) if url else None
    if kind in ("image", "video"):
        return kind
    if embed_video_url:
        return "video"
    ext = kind_from_extension(url)
    if ext:
        return ext
    return "link" if url else "none"


async def probe_kind(url: str, http: httpx.AsyncClient, timeout: float = 5.0) -> str:
    """Cheap HEAD request to classify a link the server didn't describe."""
    if not is_web_url(url):
        return "link"
    try:
        r = await http.head(url, timeout=timeout, follow_redirects=True)
    except httpx.HTTPError as e:
        log.debug("HEAD %s failed: %s", url, e)
        return "link"
    return kind_from_content_type(r.headers.get("content-type")) or "link"


async def fetch_image(url: str, http: httpx.AsyncClient, max_bytes: int = MAX_IMAGE_BYTES,
                      timeout: float = 15.0) -> bytes:
    """Download an image, refusing non-http(s) URLs, non-images and anything over `max_bytes`."""
    if not is_web_url(url):
        raise ValueError(f"refusing to fetch non-http(s) URL: {url!r}")
    async with http.stream("GET", url, timeout=timeout, follow_redirects=True) as r:
        r.raise_for_status()
        ctype = r.headers.get("content-type", "")
        if ctype and not ctype.lower().startswith("image/"):
            raise NotAnImage(f"{url} is {ctype}, not an image")
        declared = r.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > max_bytes:
            raise MediaTooLarge(f"{url} is {declared} bytes (limit {max_bytes})")
        chunks: list[bytes] = []
        total = 0
        async for chunk in r.aiter_bytes():
            total += len(chunk)
            if total > max_bytes:
                raise MediaTooLarge(f"{url} exceeds {max_bytes} bytes")
            chunks.append(chunk)
    return b"".join(chunks)
