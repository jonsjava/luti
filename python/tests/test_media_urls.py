"""Media-kind detection, the image fetcher's limits, and the browser URL helpers."""
import json

import httpx
import pytest
from conftest import fx

from luti import media, urls
from luti.media import MediaTooLarge, NotAnImage, fetch_image, media_kind, probe_kind
from luti.models import Comment, Post


@pytest.mark.parametrize(("url", "ctype", "embed", "kind"), [
    ("https://x.test/a", "image/png", None, "image"),          # content type wins...
    ("https://x.test/a.html", "image/webp", None, "image"),    # ...even over the extension
    ("https://x.test/a.PNG", None, None, "image"),             # then the extension
    ("https://x.test/a.jpeg?w=200", None, None, "image"),
    ("https://x.test/clip.mp4", None, None, "video"),
    ("https://x.test/a", "video/mp4", None, "video"),
    ("https://yt.test/watch", "text/html", "https://yt.test/embed/1", "video"),
    ("https://x.test/story", "text/html", None, "link"),
    ("https://x.test/story", None, None, "link"),
    (None, None, None, "none"),
])
def test_media_kind(url, ctype, embed, kind):
    assert media_kind(url, ctype, embed) == kind


def test_is_web_url():
    assert media.is_web_url("https://a.test/x") and media.is_web_url("HTTP://a.test")
    for bad in ("file:///etc/passwd", "javascript:alert(1)", "data:image/png;base64,AA", "ftp://a.test/x",
                "//a.test/x", "", None, "http://"):
        assert not media.is_web_url(bad), bad


async def test_fetch_png_and_jpeg(image_server):
    async with httpx.AsyncClient() as http:
        png = await fetch_image(f"{image_server}/a.png", http)
        assert png.startswith(b"\x89PNG")
        try:
            jpg = await fetch_image(f"{image_server}/b.jpg", http)
        except httpx.HTTPStatusError:
            pytest.skip("Pillow not installed; no JPEG fixture")
        assert jpg.startswith(b"\xff\xd8")


async def test_fetch_size_cap(image_server):
    async with httpx.AsyncClient() as http:
        with pytest.raises(MediaTooLarge):  # declared Content-Length over the cap
            await fetch_image(f"{image_server}/big.png", http)
        with pytest.raises(MediaTooLarge):  # no length header: cap enforced while streaming
            await fetch_image(f"{image_server}/stream-big.png", http)
        with pytest.raises(MediaTooLarge):  # custom cap
            await fetch_image(f"{image_server}/a.png", http, max_bytes=10)


async def test_fetch_rejects_non_images_and_non_http(image_server, tmp_path):
    async with httpx.AsyncClient() as http:
        with pytest.raises(NotAnImage):
            await fetch_image(f"{image_server}/page.html", http)
        secret = tmp_path / "secret.png"
        secret.write_bytes(b"x")
        for bad in (f"file://{secret}", "javascript:alert(1)", "data:image/png;base64,AA"):
            with pytest.raises(ValueError):
                await fetch_image(bad, http)


async def test_probe_kind_uses_head(image_server):
    async with httpx.AsyncClient() as http:
        assert await probe_kind(f"{image_server}/noext", http) == "image"
        assert await probe_kind(f"{image_server}/page.html", http) == "link"
        assert await probe_kind("http://127.0.0.1:9/nothing", http, timeout=1) == "link"  # unreachable
        assert await probe_kind("file:///etc/passwd", http) == "link"


# -- URL helpers ------------------------------------------------------------------
def _post(v, **fields):
    view = json.loads(json.dumps(fx(f"{v}_post_get")["post_view"]))
    view["post"].update(fields)
    return Post.parse(v, view)


@pytest.mark.parametrize("v", ["v3", "v4"])
def test_url_helpers(v):
    p = _post(v, url="https://news.test/story", thumbnail_url="https://img.test/t.jpg")
    assert urls.post_url(p, "http://localhost:8536/") == f"http://localhost:8536/post/{p.id}"
    assert urls.post_url(p, "lemmy.test") == f"https://lemmy.test/post/{p.id}"
    assert urls.link_url(p) == "https://news.test/story"
    assert urls.media_url(p) == "https://img.test/t.jpg"  # a link post's media is its thumbnail
    assert urls.origin_url(p) == p.ap_id and p.ap_id.startswith("http")
    assert urls.page_url(p, "lemmy.test") == urls.post_url(p, "lemmy.test")
    assert urls.page_url(p, "lemmy.test", prefer_origin=True) == p.ap_id

    img = _post(v, url="https://img.test/cat.png", embed_video_url="https://v.test/e")
    assert urls.media_url(img) == "https://img.test/cat.png"
    vid = _post(v, url="https://v.test/watch", embed_video_url="https://v.test/embed/1", url_content_type="text/html")
    assert urls.media_url(vid) == "https://v.test/watch"  # url first, then the embed, then the thumbnail
    embed_only = _post(v, url="ftp://v.test/x", embed_video_url="https://v.test/embed/1")
    assert urls.media_url(embed_only) == "https://v.test/embed/1"
    assert urls.link_url(_post(v, url=None)) is None and urls.media_url(_post(v, url=None)) is None

    comment = Comment.parse(v, fx(f"{v}_comment_list")["comments"][0] if v == "v3"
                            else fx(f"{v}_comment_list")["items"][0])
    assert urls.comment_url(comment, "lemmy.test") == f"https://lemmy.test/comment/{comment.id}"
    assert urls.page_url(comment, "lemmy.test", prefer_origin=True) == comment.ap_id
    assert p.creator and urls.person_url(p.creator, "lemmy.test").startswith("https://lemmy.test/u/")
    assert p.community and urls.community_url(p.community, "lemmy.test").startswith("https://lemmy.test/c/")


@pytest.mark.parametrize("v", ["v3", "v4"])
def test_url_helpers_ignore_non_http(v):
    p = _post(v, url="javascript:alert(1)", thumbnail_url="file:///etc/passwd", embed_video_url="data:text/html,x")
    assert urls.link_url(p) is None and urls.media_url(p) is None


def test_open_in_browser_only_opens_http(monkeypatch):
    opened = []
    import webbrowser
    monkeypatch.setattr(webbrowser, "open", lambda url, new=0: opened.append((url, new)) or True)
    for bad in ("file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "", None, "mailto:a@b.test"):
        assert urls.open_in_browser(bad) is False
    assert opened == []
    assert urls.open_in_browser("https://lemmy.test/post/1") is True
    assert opened == [("https://lemmy.test/post/1", 2)]
