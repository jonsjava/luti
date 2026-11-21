"""TUI-side media helpers that don't need a server."""
import io

import pytest

pytest.importorskip("textual")
from conftest import tiny_png

from luti.models import Post
from luti.tui import media as tm


def test_markdown_images_http_only():
    text = "hi ![a cat](https://i.test/cat.png) and ![x](file:///etc/passwd) ![](javascript:alert(1)) ![b](http://i.test/b.gif)"
    assert [(m.url, m.alt) for m in tm.markdown_images(text)] == [("https://i.test/cat.png", "a cat"), ("http://i.test/b.gif", "b")]
    assert tm.markdown_images(None) == []


def test_post_media_and_viewers():
    img = Post(id=1, title="t", url="https://i.test/a.png", alt_text="alt")
    m = tm.post_media(img)
    assert (m.kind, m.url, m.alt) == ("image", "https://i.test/a.png", "alt")
    assert isinstance(tm.viewer_for(m), tm.ImageViewer)
    vid = Post(id=2, title="t", url="https://v.test/w", embed_video_url="https://v.test/e", thumbnail_url="https://v.test/t.jpg")
    m = tm.post_media(vid)
    assert (m.kind, m.url, m.link) == ("video", "https://v.test/t.jpg", "https://v.test/w")
    assert isinstance(tm.viewer_for(m), tm.VideoPreviewViewer)
    assert tm.post_media(Post(id=3, title="t", url="https://news.test/x")) is None
    assert tm.post_media(Post(id=4, title="t", url="javascript:alert(1).png")) is None


def test_decode_downscales_and_rejects_garbage():
    pytest.importorskip("PIL")
    img = tm.decode(tiny_png(3000, 20))
    assert max(img.size) <= tm.DISPLAY_MAX
    with pytest.raises(Exception):  # noqa: B017 - any Pillow error is fine, it must not be returned
        tm.decode(b"not an image")


def test_decode_refuses_decompression_bomb(monkeypatch):
    PIL = pytest.importorskip("PIL.Image")
    monkeypatch.setattr(tm, "MAX_PIXELS", 1000)
    with pytest.raises((PIL.DecompressionBombError, PIL.DecompressionBombWarning, ValueError)):
        tm.decode(tiny_png(100, 100))


async def test_image_cache_memory_and_disk(image_server, tmp_path):
    cache = tm.ImageCache()
    url = f"{image_server}/a.png"
    first = await cache.get(url)
    assert first.startswith(b"\x89PNG")
    assert await cache.get(url) == first  # memory hit
    await cache.aclose()
    again = tm.ImageCache()  # fresh memory, same disk cache
    again._download = None  # a network fetch would now raise TypeError
    assert await again.get(url) == first
    await again.aclose()
    with pytest.raises(Exception):  # noqa: B017
        await tm.ImageCache().get(f"{image_server}/big.png")
    assert io  # keep the import for readers who want to extend this
