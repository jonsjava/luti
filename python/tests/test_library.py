"""The core library on its own: import hygiene, SyncClient, injected clients, .raw."""
import json
import subprocess
import sys
import textwrap

import httpx
import pytest
import respx
from conftest import fx

import luti
from luti import ApiError, AuthError, LemmyClient, LutiError, SyncClient, UnsupportedOperation
from luti.models import Comment, Community, Person, Post

BASE = "https://lemmy.test"


def run_py(code: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-c", textwrap.dedent(code)], capture_output=True, text=True, timeout=60)


def test_core_import_does_not_load_textual():
    r = run_py("""
        import sys
        import luti, luti.client, luti.models, luti.spec, luti.config, luti.errors
        import luti.stars, luti.urls, luti.media, luti.sync, luti.api
        heavy = sorted(m for m in ("textual", "textual_image", "PIL", "rich", "webbrowser", "keyring") if m in sys.modules)
        print(",".join(heavy))
    """)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == ""


def test_core_import_is_silent():
    r = run_py("import luti, luti.client, luti.stars, luti.urls, luti.media")
    assert r.returncode == 0 and r.stdout == "" and r.stderr == ""


def test_tui_entry_point_without_textual_prints_hint():
    r = run_py("""
        import sys
        class Block:
            def find_spec(self, name, path=None, target=None):
                if name == "textual" or name.startswith("textual."):
                    raise ImportError("blocked for test")
        sys.meta_path.insert(0, Block())
        from luti.tui import main
        sys.exit(main([]))
    """)
    assert r.returncode == 2
    assert 'pip install "luti[tui]"' in r.stderr + r.stdout


def test_public_surface():
    assert luti.__version__
    for name in ("LemmyClient", "Lemmy", "SyncClient", "LutiError", "AuthError", "ApiError", "UnsupportedOperation"):
        assert name in luti.__all__
        assert hasattr(luti, name)
    assert issubclass(AuthError, ApiError) and issubclass(ApiError, LutiError)
    assert issubclass(UnsupportedOperation, LutiError)
    from importlib.resources import files
    assert files("luti").joinpath("py.typed").is_file()
    assert len(luti.spec.load()["ops"]) > 50


def test_api_error_carries_lemmy_code():
    e = ApiError("post.get", 400, "couldnt_find_post", "x")
    assert e.error == "couldnt_find_post" and e.status == 400 and e.op == "post.get"


@pytest.fixture
def mock():
    with respx.mock(assert_all_called=False) as m:
        m.get(f"{BASE}/api/v4/site").respond(404)
        m.get(f"{BASE}/api/v3/site").respond(200, json={"version": "0.19.13", "site_view": {}})
        yield m


async def test_injected_http_client_is_used_and_left_open(mock):
    route = mock.get(f"{BASE}/api/v3/post").respond(200, json=fx("v3_post_get"))
    async with httpx.AsyncClient() as http:
        c = LemmyClient(BASE, token="tok", http_client=http)
        data = await c.call("post.get", id=1)
        assert data["post_view"]["post"]["id"]
        await c.aclose()
        assert not http.is_closed
        sent = route.calls.last.request
        assert sent.headers["authorization"] == "Bearer tok"
        assert sent.headers["user-agent"].startswith("luti/")


async def test_unsupported_operation(mock):
    async with LemmyClient(BASE) as c:
        with pytest.raises(UnsupportedOperation):
            await c.call("notifications.list")  # v4-only op on a v3 server
        with pytest.raises(KeyError):
            await c.call("no.such.op")  # a typo is a programming error, not a server one


def test_sync_client_login_feed_vote(mock):
    mock.post(f"{BASE}/api/v3/user/login").respond(200, json={"jwt": "jwt-1"})
    mock.get(f"{BASE}/api/v3/post/list").respond(200, json=fx("v3_post_list"))
    vote = mock.post(f"{BASE}/api/v3/post/like").respond(200, json=fx("v3_post_voted"))
    with SyncClient(BASE) as lemmy:
        assert lemmy.login("alice", "pw") == "jwt-1"
        posts = lemmy.posts(sort="new").next_page()
        assert posts and all(isinstance(p, Post) for p in posts)
        voted = lemmy.vote_post(posts[0].id, "up")
        assert isinstance(voted, Post)
    assert json.loads(vote.calls.last.request.content)["score"] == 1


def test_sync_client_raises_typed_errors(mock):
    mock.post(f"{BASE}/api/v3/user/login").respond(400, json={"error": "incorrect_login"})
    with SyncClient(BASE) as lemmy, pytest.raises(AuthError):
        lemmy.login("alice", "wrong")


@pytest.mark.parametrize("v", ["v3", "v4"])
def test_models_keep_raw(v):
    view = fx(f"{v}_post_get")["post_view"]
    p = Post.parse(v, view)
    assert p.raw is view or p.raw == view
    assert "raw" not in repr(p)
    c = Community.parse(v, fx(f"{v}_community_get")["community_view"])
    assert c.raw
    person = Person.parse_view(v, fx(f"{v}_person_get")["person_view"])
    assert person.raw


def _with_media(v, **fields):
    view = json.loads(json.dumps(fx(f"{v}_post_get")["post_view"]))
    view["post"].update(fields)
    return Post.parse(v, view)


@pytest.mark.parametrize("v", ["v3", "v4"])
def test_post_media_fields(v):
    p = _with_media(v, url="https://img.test/cat", url_content_type="image/jpeg",
                    thumbnail_url="https://img.test/t.webp", alt_text="a cat")
    assert (p.media_kind, p.url_content_type, p.thumbnail_url, p.alt_text) == \
        ("image", "image/jpeg", "https://img.test/t.webp", "a cat")
    p = _with_media(v, url="https://v.test/watch?v=1", embed_video_url="https://v.test/embed/1")
    assert p.media_kind == "video" and p.embed_video_url == "https://v.test/embed/1"
    assert _with_media(v, url="https://news.test/story").media_kind == "link"
    assert _with_media(v, url=None).media_kind == "none"
    assert Comment  # comments have no media fields; images come from their Markdown
