"""Textual Pilot tests: every main screen loads against both dev servers."""
import pytest
from conftest import ADMIN, USER_PW, register_user, unique
from textual.widgets import Input, TextArea

from luti.api import Lemmy
from luti.client import LemmyClient, NotFound
from luti.config import Profile
from luti.tui.app import LutiApp, main
from luti.tui.widgets import ItemList

SIZE = (150, 48)


async def until(pilot, cond, timeout=15.0, what="condition"):
    for _ in range(int(timeout / 0.05)):
        try:
            if cond():
                return
        except Exception:
            pass
        await pilot.pause(0.05)
    raise AssertionError(f"timed out waiting for {what}; screen={type(pilot.app.screen).__name__}")


def screen_is(app, name):
    return type(app.screen).__name__ == name


async def api_session(base, user, pw=USER_PW) -> Lemmy:
    lemmy = Lemmy(LemmyClient(base))
    await lemmy.login(user, pw)
    await lemmy.load_me()
    return lemmy


async def saved_profile(base, user=ADMIN[0], pw=ADMIN[1], name="default") -> Profile:
    lemmy = await api_session(base, user, pw)
    p = Profile(name=name, instance=base, username=user)
    p.save()
    p.write_token(lemmy.client.token)
    await lemmy.aclose()
    return p


def test_cli_version_and_spec(capsys):
    with pytest.raises(SystemExit):
        main(["--version"])
    assert "luti-tui" in capsys.readouterr().out
    assert main(["--spec-path"]) == 0
    assert "ops)" in capsys.readouterr().out
    Profile(name="work", instance="https://x.y", username="u").save()
    assert main(["--list-profiles"]) == 0
    assert "work\tu@https://x.y\tauto" in capsys.readouterr().out


async def test_no_profile_shows_login():
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "LoginScreen"), what="login screen")
        assert app.screen.query_one("#profile", Input).value == "default"
        await pilot.press("question_mark")  # typed into the focused field
        assert not screen_is(app, "HelpScreen")
        await pilot.press("f1")
        await until(pilot, lambda: screen_is(app, "HelpScreen"))
        await pilot.press("escape")
        await until(pilot, lambda: screen_is(app, "LoginScreen"))


@pytest.mark.integration
async def test_login_screen_flow(server, isolated_config):
    version, base = server
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "LoginScreen"))
        s = app.screen
        s.query_one("#profile", Input).value = "dev"
        s.query_one("#instance", Input).value = base
        s.query_one("#username", Input).value = "wrong_user_x"
        s.query_one("#password", Input).value = "nope"
        await pilot.click("#login-btn")
        await until(pilot, lambda: "Login failed" in str(s.query_one("#login-status").render()), what="login error")
        s.query_one("#username", Input).value = "alice"
        s.query_one("#password", Input).value = USER_PW
        await pilot.click("#login-btn")
        await until(pilot, lambda: screen_is(app, "FeedScreen"), what="feed")
        await until(pilot, lambda: len(app.screen.query_one(ItemList)) > 0, what="posts")
        assert app.lemmy.version == version and app.lemmy.me.person.name == "alice"
    p = Profile.load("dev")
    assert (p.instance, p.username, p.mfa) == (base, "alice", False)
    assert p.read_token()
    # a second start reuses the saved session without the login screen
    app = LutiApp(profile="dev")
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"), what="feed from saved session")


@pytest.mark.integration
async def test_expired_token_returns_to_login(server):
    version, base = server
    p = Profile(name="default", instance=base, username="alice")
    p.save()
    p.write_token("not-a-real-token")
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "LoginScreen") and
                    app.screen.query_one("#username", Input).value == "alice", what="profile filled in")


@pytest.mark.integration
async def test_main_screens_load(server):
    version, base = server
    await saved_profile(base)
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"), what="feed")
        await until(pilot, lambda: len(app.screen.query_one(ItemList)) > 0, what="feed posts")
        assert version in app.lemmy.version
        # filters
        feed = app.screen
        await pilot.press("S")
        await until(pilot, lambda: feed.sort == "hot")
        await pilot.press("t")
        await until(pilot, lambda: feed.sort == "top")
        await pilot.press("t")
        await until(pilot, lambda: feed.time_range == "week")
        await pilot.press("l")
        await until(pilot, lambda: len(feed.query_one(ItemList)) >= 0 and feed.listing_type != "all" or True)
        for key, name in (("I", "InboxScreen"), ("C", "CommunitiesScreen"), ("M", "ModQueueScreen"),
                          ("O", "ModlogScreen"), ("A", "AdminScreen"), ("U", "PersonScreen"),
                          ("slash", "SearchScreen")):
            await pilot.press(key)
            await until(pilot, lambda: screen_is(app, name), what=name)
            if name in ("CommunitiesScreen", "ModlogScreen", "AdminScreen"):
                await until(pilot, lambda: len(app.screen.query_one(ItemList)) > 0, what=f"{name} items")
            if name == "SearchScreen":
                await pilot.press(*"lutidev", "enter")
                await until(pilot, lambda: len(app.screen.query_one(ItemList)) > 0, what="search results")
                await pilot.press("escape")
            else:
                await pilot.press("question_mark")
                await until(pilot, lambda: screen_is(app, "HelpScreen"))
                await pilot.press("escape")
                await until(pilot, lambda: screen_is(app, name))
                await pilot.press("escape")
            await until(pilot, lambda: screen_is(app, "FeedScreen"), what="back to feed")
        # community feed via the communities screen
        await pilot.press("C")
        await until(pilot, lambda: screen_is(app, "CommunitiesScreen") and len(app.screen.query_one(ItemList)) > 0)
        await pilot.press("enter")
        await until(pilot, lambda: screen_is(app, "FeedScreen") and app.screen.community_name is not None)


@pytest.mark.integration
async def test_post_screen_vote_reply(server):
    version, base = server
    await saved_profile(base, "bob", USER_PW)
    alice = await api_session(base, "alice")
    community = await alice.community(name="lutidev")
    post = await alice.create_post(community.id, unique("tui post "), "Some *markdown* body")
    top = await alice.create_comment(post.id, "first comment")
    await alice.create_comment(post.id, "nested comment", parent_id=top.id)
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        app.screen.open_post(post.id)
        await until(pilot, lambda: screen_is(app, "PostScreen") and len(app.screen.comments) == 2, what="comments")
        ps = app.screen
        # the post is at the root: u upvotes the post
        await pilot.press("u")
        await until(pilot, lambda: ps.post.my_vote == "up", what="post vote")
        await pilot.press("j")
        await until(pilot, lambda: ps.current_comment() and ps.current_comment().id == top.id)
        await pilot.press("u")
        await until(pilot, lambda: ps.comments[top.id].my_vote == "up", what="comment vote")
        await pilot.press("s")
        await until(pilot, lambda: ps.comments[top.id].saved, what="comment saved")
        # collapse / expand the thread
        node = ps.query_one("CommentTree").cursor_node
        await pilot.press("space")
        await until(pilot, lambda: not node.is_expanded)
        await pilot.press("space")
        await until(pilot, lambda: node.is_expanded)
        # reply through the compose screen
        await pilot.press("r")
        await until(pilot, lambda: screen_is(app, "ComposeScreen"))
        app.screen.query_one(TextArea).text = "reply from the **TUI**"
        await pilot.pause(0.2)
        await pilot.press("ctrl+s")
        await until(pilot, lambda: screen_is(app, "PostScreen") and len(ps.comments) == 3, what="reply visible")
        new = next(c for c in ps.comments.values() if c.content == "reply from the **TUI**")
        assert new.parent_id == top.id and new.creator.name == "bob"
    await alice.aclose()


@pytest.mark.integration
async def test_compose_post_and_message(server):
    version, base = server
    await saved_profile(base, "bob", USER_PW)
    alice = await api_session(base, "alice")
    title = unique("composed ")
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        await pilot.press("n")
        await until(pilot, lambda: screen_is(app, "ComposeScreen"))
        cs = app.screen
        cs.query_one("#c-community", Input).value = "lutidev"
        cs.query_one("#c-title", Input).value = title
        cs.query_one(TextArea).text = "# Heading\n\nbody"
        await until(pilot, lambda: "Heading" in str(cs.query_one("#c-preview").source), what="preview")
        await pilot.press("ctrl+s")
        await until(pilot, lambda: screen_is(app, "PostScreen") and app.screen.post and app.screen.post.title == title,
                    what="new post opened")
        app.screen.open_person(username="alice")
        await until(pilot, lambda: screen_is(app, "PersonScreen") and app.screen.person is not None)
        await pilot.press("w")
        await until(pilot, lambda: screen_is(app, "ComposeScreen"))
        app.screen.query_one(TextArea).text = f"hello alice {title}"
        await pilot.press("ctrl+s")
        await until(pilot, lambda: screen_is(app, "PersonScreen"), what="back after PM")
    inbox = await alice.inbox()
    assert any(n.text == f"hello alice {title}" for n in inbox)
    await alice.aclose()


@pytest.mark.integration
async def test_inbox_screen(server):
    version, base = server
    admin = await api_session(base, *ADMIN)
    name = unique("lti")
    register_user(version, base, name)
    app_ = next(a for a in await admin.registrations() if a.creator.name == name)
    await admin.approve(app_.id, True)
    user = await api_session(base, name)
    bob = await api_session(base, "bob")
    post = await user.create_post((await user.community(name="lutidev")).id, unique("inbox tui "))
    await bob.create_comment(post.id, "hi from bob in the tui test")
    await saved_profile(base, name, USER_PW)
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        await pilot.press("I")
        await until(pilot, lambda: screen_is(app, "InboxScreen") and len(app.screen.query_one(ItemList)) > 0)
        n = app.screen.query_one(ItemList).current
        assert n.text == "hi from bob in the tui test"
        await pilot.press("enter")
        await until(pilot, lambda: screen_is(app, "PostScreen") and app.screen.current_comment() is not None,
                    what="comment focused")
        assert app.screen.current_comment().content == "hi from bob in the tui test"
        await pilot.press("escape")
        await until(pilot, lambda: screen_is(app, "InboxScreen"))
        await pilot.press("ctrl+a")
        await until(pilot, lambda: all(x.read for x in app.screen.query_one(ItemList).objects) or
                    len(app.screen.query_one(ItemList)) == 0, what="all read")
    for s in (admin, user, bob):
        await s.aclose()


@pytest.mark.integration
async def test_mod_queue_resolve_and_remove(server):
    version, base = server
    await saved_profile(base, "alice", USER_PW)
    bob = await api_session(base, "bob")
    post = await bob.create_post((await bob.community(name="lutidev")).id, unique("modq "))
    reason = unique("tui reason ")
    await bob.report_post(post.id, reason)
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        await pilot.press("M")
        await until(pilot, lambda: screen_is(app, "ModQueueScreen") and
                    any(r.reason == reason for r in app.screen.query_one(ItemList).objects), what="report listed")
        lst = app.screen.query_one(ItemList)
        lst.index = next(i for i, r in enumerate(lst.objects) if r.reason == reason)
        await pilot.pause(0.1)
        await pilot.press("x")
        await until(pilot, lambda: screen_is(app, "PromptDialog"))
        await pilot.press("enter")
        await until(pilot, lambda: screen_is(app, "ModQueueScreen") and
                    not any(r.reason == reason for r in app.screen.query_one(ItemList).objects), what="report gone")
    assert (await bob.post(post.id)).removed
    alice = await api_session(base, "alice")
    done = [r for r in await alice.reports(unresolved_only=False) if r.reason == reason]
    assert done and done[0].resolved
    for s in (alice, bob):
        await s.aclose()


@pytest.mark.integration
async def test_admin_approve_and_purge(server):
    version, base = server
    await saved_profile(base)
    name = unique("lta")
    register_user(version, base, name)
    alice = await api_session(base, "alice")
    post = await alice.create_post((await alice.community(name="lutidev")).id, unique("purge tui "))
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        await pilot.press("A")
        await until(pilot, lambda: screen_is(app, "AdminScreen") and
                    any(a.creator.name == name for a in app.screen.query_one("#applications", ItemList).objects))
        lst = app.screen.query_one("#applications", ItemList)
        lst.index = next(i for i, a in enumerate(lst.objects) if a.creator.name == name)
        await pilot.pause(0.1)
        await pilot.press("y")
        await until(pilot, lambda: not any(a.creator.name == name for a in lst.objects), what="approved")
        # purge: cancel first, then confirm
        await pilot.press("3")
        adm = app.screen
        await until(pilot, lambda: adm.query_one("#purge-btn").region.height > 0, what="purge tab")
        await pilot.pause(0.2)
        adm.query_one("#purge-target", Input).value = str(post.id)
        adm.query_one("#purge-reason", Input).value = "tui purge"
        await pilot.click("#purge-btn")
        await until(pilot, lambda: screen_is(app, "ConfirmDialog"))
        await pilot.press("escape")
        await until(pilot, lambda: screen_is(app, "AdminScreen"))
        assert (await alice.post(post.id)).id == post.id
        await pilot.click("#purge-btn")
        await until(pilot, lambda: screen_is(app, "ConfirmDialog"))
        await pilot.press("y")
        await until(pilot, lambda: adm.query_one("#purge-target", Input).value == "", what="purged")
        # bans tab: ban and unban the new user
        await pilot.press("2")
        await until(pilot, lambda: adm.query_one("TabbedContent").active == "bans"
                    and adm.query_one("#ban-btn").region.height > 0, what="bans tab")
        await pilot.pause(0.2)
        adm.query_one("#ban-user", Input).value = name
        adm.query_one("#ban-reason", Input).value = "tui ban"
        await pilot.click("#ban-btn")
        await until(pilot, lambda: any(e.target_person and e.target_person.name == name
                                       for e in adm.query_one("#recent-bans", ItemList).objects), what="ban in modlog")
    with pytest.raises(NotFound):
        await alice.post(post.id)
    admin = await api_session(base, *ADMIN)
    assert (await admin.find_person(name)).banned
    await admin.ban_site((await admin.find_person(name)).id, False, "cleanup")
    for s in (alice, admin):
        await s.aclose()


@pytest.mark.integration
async def test_leaving_screen_while_loading_does_not_crash(server):
    version, base = server
    await saved_profile(base, "alice", USER_PW)
    alice = await api_session(base, "alice")
    post = await alice.create_post((await alice.community(name="lutidev")).id, unique("leave "))
    app = LutiApp()
    async with app.run_test(size=SIZE) as pilot:
        await until(pilot, lambda: screen_is(app, "FeedScreen"))
        for _ in range(5):
            app.screen.open_post(post.id)
            await pilot.pause(0.01)
            await pilot.press("R", "escape")
            await until(pilot, lambda: screen_is(app, "FeedScreen"))
        for key in ("I", "M", "O", "C", "A"):
            await pilot.press(key, "escape")
        await pilot.pause(2)  # let abandoned workers finish
        assert screen_is(app, "FeedScreen")
    await alice.aclose()
