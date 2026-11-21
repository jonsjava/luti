"""Images in the terminal, behind a small MediaViewer interface.

v1 ships `ImageViewer` (images) and `VideoPreviewViewer` (a video's thumbnail
with a badge; playback opens externally). A v1.1 video player plugs in as one
more MediaViewer without touching the screens: they only call `viewer_for()`.

Rendering uses textual-image: Kitty (TGP) or Sixel when the terminal supports
them, otherwise Unicode half-blocks. Protocol detection queries the terminal,
so `init_backend()` must run before the Textual app starts.

Image bytes are untrusted: downloads are http(s) only, size-capped and decoded
by Pillow with a pixel limit, off the UI thread. The fetching HTTP client is
separate from the Lemmy client, so the login token never goes to image hosts.
"""
from __future__ import annotations

import asyncio
import hashlib
import io
import logging
import os
import re
import warnings
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any, ClassVar

import httpx
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Center, Vertical
from textual.screen import ModalScreen
from textual.widget import Widget
from textual.widgets import Label, Static

from ..config import cache_root
from ..media import MAX_IMAGE_BYTES, fetch_image, is_web_url, kind_from_extension
from ..models import Post

log = logging.getLogger("luti")

MAX_PIXELS = 40_000_000  # refuse decompression bombs
DISPLAY_MAX = 1600  # downscale big images before handing them to the renderer
DISK_CACHE_BYTES = 64 * 1024 * 1024
MEMORY_CACHE_ITEMS = 48
FETCH_CONCURRENCY = 4

_backend: dict[str, Any] = {"mode": "off", "protocol": "none", "widget": None, "halfcell": None}


# --------------------------------------------------------------------------
# backend
# --------------------------------------------------------------------------
def init_backend(mode: str = "auto", force: str | None = None) -> str:
    """Load textual-image (querying the terminal) unless images are off.

    mode: auto / on / off (the profile's `images` setting).
    force: "halfcell" to skip detection (tests, LUTI_IMAGE_BACKEND=halfcell).
    Returns the protocol in use: tgp / sixel / halfcell / none.
    """
    mode = (mode or "auto").lower()
    force = force or os.environ.get("LUTI_IMAGE_BACKEND")
    _backend["mode"] = mode if mode in ("auto", "on", "off") else "auto"
    if _backend["mode"] == "off":
        _backend["protocol"] = "none"
        return "none"
    # textual-image logs a warning with a traceback when the terminal doesn't answer its
    # capability probe; without a handler Python prints that over the UI. It still falls
    # back to half-blocks, so keep it out of the terminal unless logging is configured.
    ti_log = logging.getLogger("textual_image")
    if not ti_log.handlers and not logging.getLogger().handlers:
        ti_log.addHandler(logging.NullHandler())
    try:
        if force == "halfcell":
            from textual_image.widget import HalfcellImage

            _backend.update(protocol="halfcell", widget=HalfcellImage, halfcell=HalfcellImage)
            return "halfcell"
        from textual_image.renderable import Image as Renderable
        from textual_image.renderable.sixel import Image as SixelR
        from textual_image.renderable.tgp import Image as TGPR
        from textual_image.widget import HalfcellImage
        from textual_image.widget import Image as AutoWidget
    except Exception as e:  # missing extra or a broken terminal query
        log.warning("images disabled: %s", e)
        _backend.update(mode="off", protocol="none")
        return "none"
    if Renderable is SixelR:
        protocol, widget = "sixel", AutoWidget
    elif Renderable is TGPR:
        protocol, widget = "tgp", AutoWidget
    else:
        protocol, widget = "halfcell", HalfcellImage
    _backend.update(protocol=protocol, widget=widget, halfcell=HalfcellImage)
    return protocol


def images_enabled() -> bool:
    return _backend["mode"] != "off" and _backend["widget"] is not None


def thumbnails_enabled() -> bool:
    """Feed thumbnails: always with images=on; with auto only on a real graphics protocol."""
    if not images_enabled():
        return False
    return _backend["mode"] == "on" or _backend["protocol"] in ("tgp", "sixel")


def protocol() -> str:
    return _backend["protocol"]


# --------------------------------------------------------------------------
# cache + fetch
# --------------------------------------------------------------------------
class ImageCache:
    """In-memory LRU plus a size-limited on-disk cache under $XDG_CACHE_HOME/luti/images."""

    def __init__(self, max_bytes: int = MAX_IMAGE_BYTES, disk_bytes: int = DISK_CACHE_BYTES,
                 http: httpx.AsyncClient | None = None):
        self.max_bytes = max_bytes
        self.disk_bytes = disk_bytes
        self.dir = cache_root() / "images"
        self._memory: OrderedDict[str, bytes] = OrderedDict()
        self._http = http
        self._sem = asyncio.Semaphore(FETCH_CONCURRENCY)
        self._inflight: dict[str, asyncio.Task] = {}
        self._failed: dict[str, BaseException] = {}

    def _client(self) -> httpx.AsyncClient:
        if self._http is None:
            self._http = httpx.AsyncClient(
                timeout=httpx.Timeout(15.0, connect=5.0), follow_redirects=True,
                headers={"User-Agent": "luti-tui image fetcher", "Accept": "image/*"},
            )
        return self._http

    def _path(self, url: str):
        return self.dir / hashlib.sha256(url.encode()).hexdigest()

    def _remember(self, url: str, data: bytes) -> None:
        self._memory[url] = data
        self._memory.move_to_end(url)
        while len(self._memory) > MEMORY_CACHE_ITEMS:
            self._memory.popitem(last=False)

    def _disk_get(self, url: str) -> bytes | None:
        path = self._path(url)
        try:
            data = path.read_bytes()
            os.utime(path)
            return data
        except OSError:
            return None

    def _disk_put(self, url: str, data: bytes) -> None:
        try:
            self.dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            tmp = self._path(url).with_suffix(".tmp")
            tmp.write_bytes(data)
            os.replace(tmp, self._path(url))
            self._prune()
        except OSError as e:
            log.debug("image cache write failed: %s", e)

    def _prune(self) -> None:
        files = [(p.stat().st_mtime, p.stat().st_size, p) for p in self.dir.iterdir() if p.is_file()]
        total = sum(size for _, size, _ in files)
        for _, size, path in sorted(files):
            if total <= self.disk_bytes:
                break
            try:
                path.unlink()
                total -= size
            except OSError:
                pass

    async def get(self, url: str) -> bytes:
        if not is_web_url(url):
            raise ValueError(f"not an http(s) URL: {url!r}")
        if url in self._memory:
            self._memory.move_to_end(url)
            return self._memory[url]
        data = await asyncio.to_thread(self._disk_get, url)
        if data is not None and len(data) <= self.max_bytes:
            self._remember(url, data)
            return data
        failed = self._failed.get(url)
        if failed is not None:
            raise failed
        if url not in self._inflight:
            task = asyncio.ensure_future(self._download(url))
            task.add_done_callback(self._settle)
            self._inflight[url] = task
        try:
            return await asyncio.shield(self._inflight[url])
        finally:
            task = self._inflight.get(url)
            if task is not None and task.done():
                self._inflight.pop(url, None)

    def _settle(self, task: "asyncio.Future[bytes]") -> None:
        # Retrieve the exception even if every waiter went away (screen closed), and
        # remember the failure so a dead link isn't refetched on every re-render.
        if task.cancelled():
            return
        exc = task.exception()
        if exc is not None:
            url = next((u for u, t in self._inflight.items() if t is task), None)
            if url is not None:
                self._failed[url] = exc
                self._inflight.pop(url, None)

    async def _download(self, url: str) -> bytes:
        async with self._sem:
            data = await fetch_image(url, self._client(), self.max_bytes)
        self._remember(url, data)
        await asyncio.to_thread(self._disk_put, url, data)
        return data

    async def aclose(self) -> None:
        if self._http is not None:
            await self._http.aclose()


def decode(data: bytes, max_side: int = DISPLAY_MAX):
    """Decode untrusted bytes with Pillow (pixel-limited), downscaled, as RGB(A)."""
    from PIL import Image as PILImage

    PILImage.MAX_IMAGE_PIXELS = MAX_PIXELS
    with warnings.catch_warnings():
        warnings.simplefilter("error", PILImage.DecompressionBombWarning)
        img = PILImage.open(io.BytesIO(data))
        img.load()
    if getattr(img, "is_animated", False):
        img.seek(0)
    img = img.convert("RGBA" if img.mode in ("RGBA", "LA", "P") else "RGB")
    img.thumbnail((max_side, max_side))
    return img


# --------------------------------------------------------------------------
# media description
# --------------------------------------------------------------------------
@dataclass
class Media:
    """What a viewer renders: the URL to show and what it is."""

    kind: str  # image / video
    url: str  # image to display (the image itself, or a video's thumbnail)
    link: str  # what `o`/`m` should open
    alt: str = ""
    nsfw: bool = False


_MD_IMAGE = re.compile(r"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")


def markdown_images(text: str | None) -> list[Media]:
    """Images embedded in Markdown (`![alt](url)`), http(s) only."""
    out = []
    for alt, url in _MD_IMAGE.findall(text or ""):
        if is_web_url(url):
            out.append(Media("image", url, url, alt))
    return out


def post_media(post: Post) -> Media | None:
    """The image (or video preview) to show for a post, if any."""
    kind = post.media_kind
    if kind == "image" and is_web_url(post.url):
        return Media("image", post.url, post.url, post.alt_text or "", post.nsfw)  # type: ignore[arg-type]
    if kind == "video":
        thumb = post.thumbnail_url if is_web_url(post.thumbnail_url) else None
        link = post.url if is_web_url(post.url) else post.embed_video_url or ""
        return Media("video", thumb or "", link, post.alt_text or post.embed_title or "", post.nsfw)
    if is_web_url(post.thumbnail_url):  # link post with a preview image
        return Media("image", post.thumbnail_url, post.url or post.thumbnail_url, post.alt_text or "", post.nsfw)  # type: ignore[arg-type]
    return None


def thumbnail_for(post: Post) -> str | None:
    if is_web_url(post.thumbnail_url):
        return post.thumbnail_url
    if post.media_kind == "image" and is_web_url(post.url):
        return post.url
    return None


# --------------------------------------------------------------------------
# viewers
# --------------------------------------------------------------------------
class MediaViewer:
    """Renders one kind of media. Register new kinds in VIEWERS (v1.1: video playback)."""

    kinds: ClassVar[tuple[str, ...]] = ()

    def can_handle(self, media: Media) -> bool:
        return media.kind in self.kinds

    def mount(self, media: Media, cache: ImageCache, *, full: bool = False, revealed: bool = True) -> Widget:
        raise NotImplementedError


class ImageViewer(MediaViewer):
    kinds = ("image",)

    def mount(self, media: Media, cache: ImageCache, *, full: bool = False, revealed: bool = True) -> Widget:
        return ImagePanel(media, cache, full=full, revealed=revealed)


class VideoPreviewViewer(MediaViewer):
    """v1: the video's thumbnail with a badge. Playback is v1.1; `m`/`o` open it externally."""

    kinds = ("video",)

    def mount(self, media: Media, cache: ImageCache, *, full: bool = False, revealed: bool = True) -> Widget:
        return ImagePanel(media, cache, full=full, revealed=revealed, badge="▶ video — press m to open")


VIEWERS: list[MediaViewer] = [ImageViewer(), VideoPreviewViewer()]


def viewer_for(media: Media) -> MediaViewer | None:
    return next((v for v in VIEWERS if v.can_handle(media)), None)


class ImagePanel(Vertical):
    """Placeholder, then the image (or a short error). Fetching never blocks the UI."""

    DEFAULT_CSS = """
    ImagePanel { height: auto; width: 1fr; margin: 1 0 0 0; }
    ImagePanel .media-note { color: $text-muted; height: auto; }
    ImagePanel .media-image { width: auto; height: auto; max-height: 20; }
    ImagePanel.full .media-image { max-height: 100%; }
    ImagePanel.full { height: 1fr; align: center middle; }
    """

    def __init__(self, media: Media, cache: ImageCache, *, full: bool = False, revealed: bool = True,
                 badge: str | None = None):
        super().__init__(classes="full" if full else "")
        self.media = media
        self.cache = cache
        self.full = full
        self.revealed = revealed or not media.nsfw
        self.badge = badge
        self.loaded = False
        self.error: str | None = None

    def compose(self) -> ComposeResult:
        if self.badge:
            yield Label(f"[b reverse] {self.badge} [/]", classes="media-note")
        if not self.revealed:
            yield Label("[b red]NSFW[/] image hidden — press v to reveal", classes="media-note", id="media-status")
        elif not images_enabled():
            yield Label(f"[dim]image: {self.media.url}[/]", classes="media-note", id="media-status")
        elif not self.media.url:
            yield Label("[dim](no preview)[/]", classes="media-note", id="media-status")
        else:
            yield Label("[dim]⏳ loading image…[/]", classes="media-note", id="media-status")

    def on_mount(self) -> None:
        if self.revealed and images_enabled() and self.media.url:
            self.run_worker(self._load(), exclusive=True, group="image")

    def reveal(self) -> None:
        if self.revealed:
            return
        self.revealed = True
        status = self.query_one("#media-status", Label)
        if images_enabled() and self.media.url:
            status.update("[dim]⏳ loading image…[/]")
            self.run_worker(self._load(), exclusive=True, group="image")
        else:
            status.update(f"[dim]image: {self.media.url}[/]")

    async def _load(self) -> None:
        status = self.query_one("#media-status", Label)
        try:
            data = await self.cache.get(self.media.url)
            img = await asyncio.to_thread(decode, data)
        except Exception as e:  # network, size cap, not an image, bad bytes
            self.error = str(e)
            status.update(f"[dim]image unavailable ({type(e).__name__}): {self.media.url}[/]")
            return
        widget_cls = _backend["widget"]
        if not self.is_attached:
            return
        await self.mount(widget_cls(img, classes="media-image"))
        caption = self.media.alt or ""
        status.update(f"[dim]{caption}[/]" if caption else "")
        status.display = bool(caption)
        self.loaded = True


class Thumbnail(Widget):
    """A small image at the start of a feed row."""

    DEFAULT_CSS = """
    Thumbnail { width: 10; height: 4; margin-right: 1; }
    Thumbnail > * { width: 10; height: 4; }
    """

    def __init__(self, url: str, cache: ImageCache):
        super().__init__()
        self.url = url
        self.cache = cache

    def compose(self) -> ComposeResult:
        yield Static("[dim]…[/]")

    def on_mount(self) -> None:
        self.run_worker(self._load(), exclusive=True)

    async def _load(self) -> None:
        try:
            img = await asyncio.to_thread(decode, await self.cache.get(self.url), 256)
        except Exception as e:  # dead link, too big, not an image: keep the placeholder
            log.debug("thumbnail %s: %s", self.url, e)
            img = None
        # The row may have been re-rendered or removed while we were downloading.
        placeholder = self.query(Static).first() if self.is_attached and self.query(Static) else None
        if placeholder is None:
            return
        if img is None:
            placeholder.update("[dim]▢[/]")
            return
        await placeholder.remove()
        await self.mount(_backend["widget"](img))


class ImageScreen(ModalScreen[None]):
    """Full-screen view of one image, fitted to the terminal."""

    BINDINGS = [
        Binding("escape,q,i", "close", "Close"),
        Binding("m,o", "open_external", "Open in browser"),
        Binding("v", "reveal", "Reveal", show=False),
    ]
    DEFAULT_CSS = """
    ImageScreen { align: center middle; background: $background 95%; }
    ImageScreen > Vertical { width: 100%; height: 100%; padding: 1 2; }
    ImageScreen #image-caption { height: auto; width: 1fr; color: $text-muted; }
    """

    def __init__(self, media: Media, cache: ImageCache, revealed: bool = True):
        super().__init__()
        self.media = media
        self.cache = cache
        self.revealed = revealed

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(f"{self.media.alt or self.media.link}  [dim](esc close · m open in browser)[/]",
                        id="image-caption")
            with Center():
                viewer = viewer_for(self.media)
                if viewer:
                    yield viewer.mount(self.media, self.cache, full=True, revealed=self.revealed)

    def action_close(self) -> None:
        self.dismiss(None)

    def action_reveal(self) -> None:
        for panel in self.query(ImagePanel):
            panel.reveal()

    def action_open_external(self) -> None:
        open_external(self.app, self.media.link or self.media.url)


def open_external(app: Any, url: str | None) -> bool:
    """Open an http(s) URL in the system browser on a worker thread."""
    from ..urls import open_in_browser

    if not is_web_url(url):
        app.notify("Nothing to open (only http/https links are opened)", severity="warning")
        return False
    app.run_worker(lambda: open_in_browser(url), thread=True, group="browser")
    app.notify(f"Opening {url}")
    return True


def guess_is_image(url: str | None) -> bool:
    return kind_from_extension(url) == "image"
