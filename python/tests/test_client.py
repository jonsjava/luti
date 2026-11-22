import json

import httpx
import pytest
import respx
from conftest import fx

from luti.client import (
    ApiError,
    AuthError,
    ConnectionFailed,
    LemmyClient,
    MfaRequired,
    NotFound,
    PermissionDenied,
    RateLimited,
    UnsupportedOp,
    VersionDetectError,
    normalize_instance,
)

BASE = "https://lemmy.test"


@pytest.fixture
def mock():
    with respx.mock(assert_all_called=False) as m:
        yield m


def site_v4(m):
    m.get(f"{BASE}/api/v4/site").respond(200, json={"version": "1.0.0", "site_view": {}})


def site_v3_only(m):
    m.get(f"{BASE}/api/v4/site").respond(404, text="Not Found")
    m.get(f"{BASE}/api/v3/site").respond(200, json={"version": "0.19.21", "site_view": {}})


def test_normalize_instance():
    assert normalize_instance("lemmy.world/") == "https://lemmy.world"
    assert normalize_instance(" http://localhost:8536 ") == "http://localhost:8536"
    with pytest.raises(ValueError):
        normalize_instance("  ")


async def test_detect_prefers_v4(mock):
    site_v4(mock)
    v3 = mock.get(f"{BASE}/api/v3/site").respond(200, json={"version": "1.0.0"})
    async with LemmyClient(BASE) as c:
        assert await c.detect() == "v4"
        assert c.server_version == "1.0.0"
    assert not v3.called


async def test_detect_falls_back_to_v3(mock):
    site_v3_only(mock)
    async with LemmyClient(BASE) as c:
        assert await c.detect() == "v3"


async def test_detect_override_skips_probe(mock):
    probe = mock.get(f"{BASE}/api/v4/site").respond(200, json={"version": "1.0.0"})
    mock.get(f"{BASE}/api/v3/post/list").respond(200, json={"posts": []})
    async with LemmyClient(BASE, api="v3") as c:
        await c.call("post.list")
        assert c.version == "v3"
    assert not probe.called


async def test_detect_not_lemmy(mock):
    mock.get(f"{BASE}/api/v4/site").respond(404)
    mock.get(f"{BASE}/api/v3/site").respond(200, text="<html>hi</html>")
    async with LemmyClient(BASE) as c:
        with pytest.raises(VersionDetectError):
            await c.detect()


async def test_connection_failed(mock):
    mock.get(f"{BASE}/api/v4/site").mock(side_effect=httpx.ConnectError("boom"))
    async with LemmyClient(BASE) as c:
        with pytest.raises(ConnectionFailed):
            await c.detect()


def test_bad_api_override():
    with pytest.raises(ValueError):
        LemmyClient(BASE, api="v2")


async def test_get_sends_bearer_and_query(mock):
    site_v4(mock)
    route = mock.get(f"{BASE}/api/v4/post/list").respond(200, json={"items": [], "next_page": None})
    async with LemmyClient(BASE, token="tok") as c:
        await c.call("post.list", sort="top", time_range="week", saved_only=True, community_id=None)
    req = route.calls.last.request
    assert req.headers["Authorization"] == "Bearer tok"
    assert dict(req.url.params) == {"sort": "top", "time_range_seconds": "604800", "saved_only": "true"}


async def test_post_json_body_with_v3_transforms(mock):
    site_v3_only(mock)
    route = mock.post(f"{BASE}/api/v3/user/ban").respond(200, json={"person_view": {}, "banned": True})
    async with LemmyClient(BASE, token="t") as c:
        await c.call("admin.ban", person_id=4, ban=True, reason="spam", remove_or_restore_data=True, expires_at=123)
    assert json.loads(route.calls.last.request.content) == {
        "person_id": 4, "ban": True, "reason": "spam", "remove_data": True, "expires": 123}


async def test_v4_delete_method(mock):
    site_v4(mock)
    route = mock.delete(f"{BASE}/api/v4/post").respond(200, json={"post_view": {}})
    async with LemmyClient(BASE, token="t") as c:
        await c.call("post.delete", post_id=1, deleted=True)
    assert json.loads(route.calls.last.request.content) == {"post_id": 1, "deleted": True}


async def test_vote_on_wire(mock):
    site_v4(mock)
    route = mock.post(f"{BASE}/api/v4/comment/like").respond(200, json={"comment_view": {}})
    async with LemmyClient(BASE, token="t") as c:
        await c.call("comment.vote", comment_id=9, vote="down")
    assert json.loads(route.calls.last.request.content) == {"comment_id": 9, "is_upvote": False}


async def test_pick_v3_account(mock):
    site_v3_only(mock)
    async with LemmyClient(BASE, token="t") as c:
        me = await c.call("account.get")
    assert me is None  # the probe site has no my_user
    mock.get(f"{BASE}/api/v3/site").respond(200, json=fx("v3_account_get") | {"version": "0.19"})
    async with LemmyClient(BASE, token="t", api="v3") as c:
        me = await c.call("account.get")
    assert me["local_user_view"]["person"]["name"] == "luti_admin"


async def test_unsupported_op(mock):
    site_v4(mock)
    async with LemmyClient(BASE) as c:
        with pytest.raises(UnsupportedOp):
            await c.call("inbox.replies")
        assert not c.supports("inbox.mentions") and c.supports("notifications.list")


async def test_unknown_op(mock):
    site_v4(mock)
    async with LemmyClient(BASE) as c:
        with pytest.raises(KeyError):
            await c.call("nope")


@pytest.mark.parametrize("status,body,exc", [
    (400, {"error": "incorrect_login"}, AuthError),
    (400, {"error": "missing_totp_token"}, MfaRequired),
    (401, {"error": "not_logged_in", "message": "Not logged in"}, AuthError),
    (403, {"error": "not_a_moderator"}, PermissionDenied),
    (400, {"error": "rate_limit_error"}, RateLimited),
    (404, {"error": "not_found"}, NotFound),
    (400, {"error": "couldnt_find_object"}, NotFound),
    (400, {"error": "couldnt_find_post"}, NotFound),
    (400, {"error": "unknown", "message": "Query deserialize error"}, ApiError),
    (500, None, ApiError),
    (200, {"error": "something_odd"}, ApiError),
])
async def test_typed_errors(mock, status, body, exc):
    site_v4(mock)
    route = mock.get(f"{BASE}/api/v4/community")
    route.respond(status, json=body) if body is not None else route.respond(status, text="Internal error")
    async with LemmyClient(BASE) as c:
        with pytest.raises(exc) as info:
            await c.call("community.get", name="x")
    assert info.value.op == "community.get" and info.value.status == status
    if body:
        assert info.value.error == body["error"]


async def test_login_sets_token(mock):
    site_v4(mock)
    route = mock.post(f"{BASE}/api/v4/account/auth/login").respond(200, json={"jwt": "abc", "registration_created": False})
    async with LemmyClient(BASE) as c:
        assert await c.login("u", "p", totp="123456") == "abc"
        assert c.token == "abc"
    assert json.loads(route.calls.last.request.content) == {"username_or_email": "u", "password": "p", "totp_2fa_token": "123456"}


async def test_login_without_token_is_auth_error(mock):
    site_v3_only(mock)
    mock.post(f"{BASE}/api/v3/user/login").respond(200, json={"jwt": None, "registration_created": True})
    async with LemmyClient(BASE) as c:
        with pytest.raises(AuthError) as info:
            await c.login("u", "p")
    assert info.value.error == "registration_pending"


# -- pagination ----------------------------------------------------------------
async def test_v3_pages(mock):
    site_v3_only(mock)
    pages = {1: [1, 2], 2: [3, 4], 3: [5]}

    def handler(request):
        page = int(request.url.params["page"])
        assert request.url.params["limit"] == "2"
        return httpx.Response(200, json={"posts": [{"post": {"id": i}} for i in pages.get(page, [])]})

    route = mock.get(f"{BASE}/api/v3/post/list").mock(side_effect=handler)
    async with LemmyClient(BASE) as c:
        ids = [p["post"]["id"] async for p in c.paginate("post.list", limit=2, sort="new")]
    assert ids == [1, 2, 3, 4, 5]
    assert route.call_count == 3  # stops on the short page
    assert route.calls[0].request.url.params["sort"] == "New"


async def test_v4_cursors(mock):
    site_v4(mock)
    pages = {None: ([1, 2], "c2"), "c2": ([3, 4], "c3"), "c3": ([5], None)}

    def handler(request):
        items, nxt = pages[request.url.params.get("page_cursor")]
        assert "page" not in request.url.params
        return httpx.Response(200, json={"items": [{"post": {"id": i}} for i in items], "next_page": nxt})

    route = mock.get(f"{BASE}/api/v4/post/list").mock(side_effect=handler)
    async with LemmyClient(BASE) as c:
        ids = [p["post"]["id"] async for p in c.paginate("post.list", limit=2)]
    assert ids == [1, 2, 3, 4, 5]
    assert route.call_count == 3


async def test_paginate_max_items(mock):
    site_v4(mock)
    mock.get(f"{BASE}/api/v4/post/list").respond(200, json={"items": [{"post": {"id": i}} for i in range(10)], "next_page": "x"})
    async with LemmyClient(BASE) as c:
        got = [p async for p in c.paginate("post.list", limit=10, max_items=3)]
    assert len(got) == 3


async def test_v4_cursor_stops_on_empty_or_repeat(mock):
    site_v4(mock)
    route = mock.get(f"{BASE}/api/v4/search").respond(200, json={"posts": [], "comments": [], "communities": [], "persons": [], "next_page": "none,none"})
    async with LemmyClient(BASE) as c:
        pager = c.pager("search", 10, search_term="x")
        assert await pager.next_page() == []
        assert not pager.has_more
    assert route.call_count == 1


async def test_pager_v3_empty_first_page(mock):
    site_v3_only(mock)
    mock.get(f"{BASE}/api/v3/admin/registration_application/list").respond(200, json={"registration_applications": []})
    async with LemmyClient(BASE, token="t") as c:
        pager = c.pager("admin.registrations", 20, unread_only=True)
        assert await pager.next_page() == []
        assert not pager.has_more
        assert await pager.next_page() == []


async def test_login_retries_duplicate_token(mock, monkeypatch):
    import luti.client as client_mod

    async def no_sleep(_):
        return None

    monkeypatch.setattr(client_mod.asyncio, "sleep", no_sleep)
    site_v4(mock)
    route = mock.post(f"{BASE}/api/v4/account/auth/login")
    route.side_effect = [
        httpx.Response(400, json={"error": "unknown", "message": 'duplicate key value violates unique constraint "login_token_pkey"'}),
        httpx.Response(200, json={"jwt": "second"}),
    ]
    async with LemmyClient(BASE) as c:
        assert await c.login("u", "p") == "second"
    assert route.call_count == 2
