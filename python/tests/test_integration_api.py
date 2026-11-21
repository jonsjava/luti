"""End-to-end checks of luti's API layer against the dev servers (dev/docker-compose.yml).

Every test creates its own users and content, so it does not depend on counts
and can share the servers with other test runs.
"""
import pytest
from conftest import ADMIN, USER_PW, register_user, unique

from luti.api import Lemmy
from luti.client import ApiError, AuthError, LemmyClient, NotFound

pytestmark = pytest.mark.integration


async def session(base: str, user: str, pw: str = USER_PW) -> Lemmy:
    lemmy = Lemmy(LemmyClient(base))
    await lemmy.login(user, pw)
    await lemmy.load_me()
    return lemmy


async def new_user(version: str, base: str, admin: Lemmy) -> tuple[str, Lemmy]:
    """Register and approve a throwaway account; return (name, logged-in session)."""
    name = unique("lt")
    register_user(version, base, name)
    apps = await admin.registrations(unread_only=True)
    app = next(a for a in apps if a.creator and a.creator.name == name)
    approved = await admin.approve(app.id, True)
    assert approved.id == app.id
    return name, await session(base, name)


@pytest.fixture
async def ctx(server):
    version, base = server
    admin = await session(base, *ADMIN)
    alice = await session(base, "alice")
    bob = await session(base, "bob")
    name, user = await new_user(version, base, admin)
    community = await alice.community(name="lutidev")
    opened = [admin, alice, bob, user]
    yield {"version": version, "base": base, "admin": admin, "alice": alice, "bob": bob,
           "user": user, "name": name, "community": community}
    for s in opened:
        await s.aclose()


async def test_detect_and_login(server):
    version, base = server
    lemmy = Lemmy(LemmyClient(base))
    assert await lemmy.connect() == version
    with pytest.raises(AuthError):
        await lemmy.login("alice", "wrong-password")
    await lemmy.login(*ADMIN)
    me = await lemmy.load_me()
    assert me.person.name == "luti_admin" and me.admin
    counts = await lemmy.unread()
    assert counts.inbox >= 0 and counts.reports >= 0 and counts.applications >= 0
    await lemmy.aclose()


async def test_post_comment_vote_save(ctx):
    user, alice, cid = ctx["user"], ctx["alice"], ctx["community"].id
    title = unique("post ")
    post = await user.create_post(cid, title, "body **markdown**")
    assert post.title == title and post.creator.name == ctx["name"] and post.community.id == cid

    up = await alice.vote_post(post.id, "up")
    assert up.my_vote == "up" and up.score == 2  # creator's own vote + alice
    down = await alice.vote_post(post.id, "down")
    assert down.my_vote == "down" and down.score == 0
    cleared = await alice.vote_post(post.id, "clear")
    assert cleared.my_vote is None and cleared.score == 1

    saved = await alice.save_post(post.id, True)
    assert saved.saved
    assert (await alice.post(post.id)).saved
    assert not (await alice.save_post(post.id, False)).saved

    top = await alice.create_comment(post.id, "top level")
    reply = await user.create_comment(post.id, "a reply", parent_id=top.id)
    assert reply.parent_id == top.id
    voted = await user.vote_comment(top.id, "up")
    assert voted.my_vote == "up"
    assert (await user.save_comment(top.id, True)).saved
    comments = await user.comments(post.id)
    assert {c.id for c in comments} == {top.id, reply.id}
    assert next(c for c in comments if c.id == top.id).my_vote == "up"


async def test_feed_filters_and_pagination(ctx):
    user, cid = ctx["user"], ctx["community"].id
    tag = unique("page ")
    made = [(await user.create_post(cid, f"{tag} {i}")).id for i in range(5)]
    pager = user.posts(sort="new", community_name="lutidev", limit=2)
    seen: list[int] = []
    for _ in range(6):
        page = await pager.next_page()
        assert len(page) <= 2
        seen += [p.id for p in page]
        if set(made) <= set(seen) or not pager.has_more:
            break
    assert set(made) <= set(seen)
    assert len(seen) == len(set(seen)), "pages overlap"
    # newest first
    assert [i for i in seen if i in made] == sorted(made, reverse=True)
    for sort, time_range in (("top", "day"), ("top", None), ("most_comments", None), ("hot", None)):
        page = await user.posts(sort=sort, time_range=time_range, listing_type="local", limit=5).next_page()
        assert isinstance(page, list)
    assert any(p.id == made[0] for p in await user.posts(sort="new", listing_type="all", limit=20).next_page())
    sub = await user.posts(sort="new", listing_type="subscribed", limit=5).next_page()
    assert all(p.community.is_subscribed for p in sub)


async def test_inbox_reply_mention_pm(ctx):
    user, bob, version = ctx["user"], ctx["bob"], ctx["version"]
    post = await user.create_post(ctx["community"].id, unique("inbox "))
    await bob.create_comment(post.id, "reply for the inbox test")
    await bob.send_pm(user.me.person.id, "pm for the inbox test")
    inbox = await user.inbox()
    texts = {n.text: n for n in inbox}
    assert "reply for the inbox test" in texts and "pm for the inbox test" in texts
    reply = texts["reply for the inbox test"]
    assert reply.kind == "reply" and reply.comment.post_id == post.id and reply.creator.name == "bob"
    assert texts["pm for the inbox test"].kind == "private_message"
    assert not reply.read
    if version == "v4":
        await user.mark_read(reply)
        assert reply.text not in {n.text for n in await user.inbox(unread_only=True)}
    await user.mark_all_read()
    assert await user.inbox(unread_only=True) == []
    assert (await user.unread()).inbox == 0


async def test_report_resolve_remove(ctx):
    user, bob, alice = ctx["user"], ctx["bob"], ctx["alice"]
    post = await user.create_post(ctx["community"].id, unique("reportme "))
    comment = await user.create_comment(post.id, unique("bad comment "))
    reason = unique("reason ")
    await bob.report_post(post.id, reason)
    await bob.report_comment(comment.id, reason)
    reports = [r for r in await alice.reports() if r.reason == reason]
    assert {r.kind for r in reports} == {"post", "comment"}
    post_report = next(r for r in reports if r.kind == "post")
    assert post_report.post_id == post.id and post_report.target_creator.name == ctx["name"]
    assert not post_report.resolved

    await alice.resolve_report(post_report)
    assert reason not in {r.reason for r in await alice.reports() if r.kind == "post"}
    resolved = [r for r in await alice.reports(unresolved_only=False) if r.reason == reason and r.kind == "post"]
    assert resolved and resolved[0].resolved

    removed = await alice.remove_post(post.id, True, reason)
    assert removed.removed
    assert (await alice.remove_post(post.id, False, "restore")).removed is False
    rc = await alice.remove_comment(comment.id, True, reason)
    assert rc.removed
    log = await alice.modlog(community_id=ctx["community"].id, limit=50).next_page()
    assert any(e.action in ("mod_remove_post", "mod_remove_comment") and e.reason == reason for e in log)


async def test_community_ban_and_site_ban(ctx):
    alice, admin, name = ctx["alice"], ctx["admin"], ctx["name"]
    person = await alice.find_person(name)
    cid = ctx["community"].id
    await alice.ban_from_community(cid, person.id, True, "integration ban", expires_days=1)
    with pytest.raises(ApiError) as banned:
        await ctx["user"].create_post(cid, "should fail while banned")
    assert "banned" in banned.value.error
    await alice.ban_from_community(cid, person.id, False, "integration unban")
    assert (await ctx["user"].create_post(cid, unique("after unban "))).id

    await admin.ban_site(person.id, True, "integration site ban")
    assert (await admin.find_person(name)).banned
    await admin.ban_site(person.id, False, "integration site unban")
    assert not (await admin.find_person(name)).banned
    log = await admin.modlog(limit=50).next_page()
    assert any(e.target_person and e.target_person.name == name for e in log)


async def test_registration_deny(server):
    version, base = server
    admin = await session(base, *ADMIN)
    name = unique("ltd")
    register_user(version, base, name)
    app = next(a for a in await admin.registrations() if a.creator.name == name)
    assert app.status == "pending"
    denied = await admin.approve(app.id, False, "integration deny")
    assert denied.status == "denied"
    assert name not in {a.creator.name for a in await admin.registrations(unread_only=True)}
    await admin.aclose()


async def test_purge_post(ctx):
    user, admin = ctx["user"], ctx["admin"]
    post = await user.create_post(ctx["community"].id, unique("purge "))
    await admin.purge("post", post.id, "integration purge")
    with pytest.raises(NotFound):
        await admin.post(post.id)


async def test_search_person_communities(ctx):
    user, name = ctx["user"], ctx["name"]
    title = unique("findme")
    post = await user.create_post(ctx["community"].id, title)
    results = await user.search(title, type_="posts")
    assert any(getattr(r, "id", None) == post.id for r in results)
    results = await user.search("lutidev", type_="communities")
    assert any(getattr(r, "name", None) == "lutidev" for r in results)
    person, items = await user.person(username=name)
    assert person.name == name and any(getattr(i, "id", None) == post.id for i in items)
    communities = await user.communities(listing_type="local", sort="hot").next_page()
    assert any(c.name == "lutidev" for c in communities)
    followed = await user.follow(ctx["community"].id, True)
    assert followed.is_subscribed
    assert not (await user.follow(ctx["community"].id, False)).is_subscribed
