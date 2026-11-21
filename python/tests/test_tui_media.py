"""Pilot tests for inline images, the browser keys and the Stargaze screen."""
import webbrowser

import pytest
from conftest import ADMIN, USER_PW, tiny_jpeg, unique
from test_tui import SIZE, api_session, saved_profile, screen_is, until

from luti.stars import Stars
from luti.tui import media as tui_media
from luti.tui.app import LutiApp
from luti.tui.widgets import STARRED, ItemList

pytestmark = pytest.mark.integration


@pytest.fixture
def halfcell():
    """Force the half-block renderer (no terminal query) for the test, then turn images off again."""
    assert tui_media.init_backend("on", force="halfcell") == "halfcell"
    yield
    tui_media.init_backend("off")


@pytest.fixture
def opened(monkeypatch):
    urls: list[str] = []
    monkeypatch.setattr(webbrowser, "open", lambda url, new=0, autoraise=True: urls.append(url) or True)
    return urls


async def test_api_image_posts(server, image_server):
    _version, base = server
    alice = await api_session(base, "alice")
    try:
        community = await alice.community(name="lutidev")
        for path in ("/a.png", "/b.jpg"):
            url = f"{image_server}{path}"
            post = await alice.create_post(community.id, unique("img "), url=url, alt_text="a test image")
            got = await alice.post(post.id)
            assert got.url == url and got.media_kind == "image", (got.url, got.url_content_type)
    finally:
        await alice.aclose()


async def test_post_image_renders_with_halfcell(server, image_server, halfcell):
    version, base = server
    await saved_profile(base, "alice", USER_PW)
    alice = await api_session(base, "alice")
    # Lemmy 1.0 refuses Markdown image links to internal IPs in bodies (plain post urls are fine).
    body = f"see ![inline]({image_server}/b.jpg)" if version == "v3" else "no inline image"
    post = await alice.create_post((await alice.community(name="lutidev")).id, unique("pic "),
                                   url=f"{image_server}/a.png", body=body)
    await alice.aclose()
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        app.screen.open_post(post.id)
        await until(pilot, lambda: screen_is(app, "PostScreen") and app.screen.post is not None, what="post")
        panel = await _panel(pilot, app)
        await until(pilot, lambda: panel.loaded, what="image decoded")
        assert panel.query(".media-image"), "no image widget mounted"
        assert type(panel.query_one(".media-image")).__name__ == "HalfcellImage"
        await pilot.press("i")
        await until(pilot, lambda: screen_is(app, "ImageScreen"), what="full-screen viewer")
        await pilot.press("escape")
        await until(pilot, lambda: screen_is(app, "PostScreen"))
        if version == "v3" and tiny_jpeg():
            await until(pilot, lambda: len(app.screen.query(tui_media.ImagePanel)) >= 2, what="body image panel")
            await until(pilot, lambda: all(p.loaded for p in app.screen.query(tui_media.ImagePanel)), what="both decoded")


async def _panel(pilot, app):
    await until(pilot, lambda: app.screen.query(tui_media.ImagePanel), what="image panel")
    return app.screen.query(tui_media.ImagePanel).first()


async def test_image_too_large_shows_placeholder(server, image_server, halfcell):
    _version, base = server
    await saved_profile(base, "alice", USER_PW)
    alice = await api_session(base, "alice")
    post = await alice.create_post((await alice.community(name="lutidev")).id, unique("big "),
                                   url=f"{image_server}/big.png")
    await alice.aclose()
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        app.screen.open_post(post.id)
        panel = await _panel(pilot, app)
        await until(pilot, lambda: panel.error is not None, what="size cap error")
        assert "MediaTooLarge" in str(panel.query_one("#media-status").render())
        assert not panel.query(".media-image")


async def test_browser_keys(server, opened):
    _version, base = server
    await saved_profile(base, "alice", USER_PW)
    alice = await api_session(base, "alice")
    link = "https://example.invalid/story.html"
    post = await alice.create_post((await alice.community(name="lutidev")).id, unique("keys "), url=link)
    comment = await alice.create_comment(post.id, "a comment")
    await alice.aclose()
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        app.screen.open_post(post.id, comment.id)
        await until(pilot, lambda: screen_is(app, "PostScreen") and app.screen.selected_comment() is not None,
                    what="comment selected")
        for key in ("o", "p", "c"):
            await pilot.press(key)
        await until(pilot, lambda: len(opened) == 3, what="three opens")
        assert opened == [link, f"{base}/post/{post.id}", f"{base}/comment/{comment.id}"]
        await pilot.press("m")  # a plain link post has no media and no thumbnail here
        await pilot.pause(0.3)
        assert len(opened) == 3
        await pilot.press("y")
        await pilot.pause(0.1)
        assert app.clipboard == link


async def test_browser_media_key(server, image_server, opened):
    _version, base = server
    await saved_profile(base, "alice", USER_PW)
    alice = await api_session(base, "alice")
    url = f"{image_server}/a.png"
    post = await alice.create_post((await alice.community(name="lutidev")).id, unique("media "), url=url)
    await alice.aclose()
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        app.screen.open_post(post.id)
        await until(pilot, lambda: screen_is(app, "PostScreen") and app.screen.post is not None)
        await pilot.press("m")
        await until(pilot, lambda: opened, what="media opened")
        assert opened == [url]


async def test_stargaze_screen_and_star_toggle(server):
    _version, base = server
    await saved_profile(base, *ADMIN)
    alice = await api_session(base, "alice")
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        await pilot.press("T")
        await until(pilot, lambda: screen_is(app, "StargazeScreen"), what="stargaze screen")
        await until(pilot, lambda: "No favorites" in str(app.screen.query_one("#filter-bar").render()))
        await pilot.press("escape")
        await until(pilot, lambda: screen_is(app, "FeedScreen"))

        app.screen.open_person(username="alice")
        await until(pilot, lambda: screen_is(app, "PersonScreen") and app.screen.person is not None)
        await pilot.press("asterisk")
        stars = Stars("default")
        await until(pilot, lambda: any(u.startswith("alice@") for u in stars.list()), what="alice starred")
        who = next(u for u in stars.list() if u.startswith("alice@"))
        assert who in STARRED
        await until(pilot, lambda: stars.last_seen(who) is not None, what="baseline recorded")

        post = await alice.create_post((await alice.community(name="lutidev")).id, unique("starred "))
        await pilot.press("T")
        await until(pilot, lambda: screen_is(app, "StargazeScreen") and
                    any(getattr(o, "id", None) == post.id for o in app.screen.query_one("#stargaze-posts", ItemList).objects),
                    what="new post queued")
        assert app.stargaze_unread >= 1
        await pilot.press("n")
        await until(pilot, lambda: screen_is(app, "PostScreen"), what="next unread opened")
        assert stars.last_seen(who) >= post.id
        await pilot.press("escape")
        await until(pilot, lambda: screen_is(app, "StargazeScreen") and
                    not app.screen.query_one("#stargaze-posts", ItemList).objects, what="queue empty")

        await pilot.press("tab")
        await until(pilot, lambda: app.screen.query_one("#favorites", ItemList).has_focus)
        await pilot.press("asterisk")
        await until(pilot, lambda: who not in stars.list(), what="unstarred from sidebar")
        assert who not in STARRED
    await alice.aclose()


async def test_feed_thumbnails_and_setting(server, image_server, halfcell):
    _version, base = server
    profile = await saved_profile(base, "alice", USER_PW)
    alice = await api_session(base, "alice")
    post = await alice.create_post((await alice.community(name="lutidev")).id, unique("thumb "),
                                   url=f"{image_server}/a.png")
    await alice.aclose()

    def thumb_for(app):
        rows = [c for c in app.screen.query_one(ItemList).children if getattr(c, "obj", None) is not None
                and getattr(c.obj, "id", None) == post.id]
        return rows[0].query(tui_media.Thumbnail) if rows else None

    for enabled in (True, False):
        profile.set_setting("thumbnails", enabled)
        profile.save()
        app = LutiApp()
        async with app.run_test(size=SIZE) as pilot:
            await until(pilot, lambda: screen_is(app, "FeedScreen"))
            app.screen.sort = "new"  # the fresh post is at the top
            app.screen.reload()
            await until(pilot, lambda: thumb_for(app) is not None, what="post row")
            assert bool(thumb_for(app)) is enabled
