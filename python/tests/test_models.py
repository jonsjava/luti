import pytest

from luti_tui.models import (
    Comment,
    Community,
    Me,
    ModlogEntry,
    Notification,
    Person,
    Post,
    PrivateMessage,
    RegistrationApplication,
    Report,
    UnreadCounts,
    build_comment_tree,
)
from luti_tui.client import extract_items

from conftest import fx

V = ("v3", "v4")


def items(version, op, name):
    return extract_items(op, version, fx(f"{version}_{name}"))


@pytest.mark.parametrize("v", V)
def test_post_list(v):
    posts = [Post.parse(v, r) for r in items(v, "post.list", "post_list")]
    assert posts and all(p.id and p.title for p in posts)
    p = posts[0]
    assert p.creator and p.creator.name and p.creator.ap_id.startswith("http")
    assert p.community and p.community.name == "lutidev"
    assert p.published.startswith("20")
    assert isinstance(p.score, int)


@pytest.mark.parametrize("v", V)
def test_post_my_vote_saved_subscribed(v):
    p = Post.parse(v, fx(f"{v}_post_voted")["post_view"])
    assert p.title == "fixture post"
    assert p.my_vote == "up"
    assert p.saved is True
    assert p.community.subscribed == "subscribed"
    assert p.community.is_subscribed


def test_post_v4_actions_absent_means_no_vote():
    view = fx("v4_post_list")["items"][0]
    view = {**view, "post_actions": None}
    p = Post.from_v4(view)
    assert p.my_vote is None and not p.saved and not p.read


def test_post_v4_downvote():
    view = fx("v4_post_voted")["post_view"]
    view = {**view, "post_actions": {"vote_is_upvote": False}}
    assert Post.from_v4(view).my_vote == "down"


def test_post_v3_downvote():
    view = {**fx("v3_post_voted")["post_view"], "my_vote": -1}
    assert Post.from_v3(view).my_vote == "down"


@pytest.mark.parametrize("v", V)
def test_ap_id_mapping(v):
    data = fx(f"{v}_person_get")["person_view"]
    person = Person.parse_view(v, data)
    raw = data["person"]
    assert person.ap_id == (raw["actor_id"] if v == "v3" else raw["ap_id"])
    assert person.name == "bob" and person.handle == "bob"


def test_handle_for_remote():
    p = Person(id=1, name="zed", ap_id="https://far.away/u/zed", local=False)
    assert p.handle == "zed@far.away"
    c = Community(id=1, name="news", ap_id="https://far.away/c/news", local=False)
    assert c.handle == "!news@far.away"


@pytest.mark.parametrize("v", V)
def test_comment_tree(v):
    comments = [Comment.parse(v, r) for r in items(v, "comment.list", "comment_tree")]
    by_content = {c.content: c for c in comments}
    nested = by_content["alice nested"]
    parent = by_content["bob replies to alice"]
    assert nested.parent_id == parent.id and nested.depth == 1 and parent.depth == 0
    roots = build_comment_tree(comments)
    root = next(n for n in roots if n.comment.id == parent.id)
    assert [ch.comment.id for ch in root.children] == [nested.id]
    assert all(c.creator for c in comments)
    assert parent.post_title == "fixture post"


@pytest.mark.parametrize("v", V)
def test_community(v):
    c = Community.parse(v, fx(f"{v}_community_get")["community_view"])
    assert c.name == "lutidev" and c.title == "luti dev"
    assert c.subscribers is not None and c.subscribers >= 1
    assert c.ap_id.endswith("/c/lutidev")


@pytest.mark.parametrize("v", V)
def test_community_list(v):
    cs = [Community.parse(v, r) for r in items(v, "community.list", "community_list")]
    assert any(c.name == "lutidev" for c in cs)


def test_community_v4_pending_and_v3_states():
    assert Community.from_v4({"community": {"id": 1, "name": "x"}, "community_actions": {"follow_state": "pending"}}).subscribed == "pending"
    assert Community.from_v4({"community": {"id": 1, "name": "x"}}).subscribed == "not_subscribed"
    assert Community.from_v3({"community": {"id": 1, "name": "x"}, "subscribed": "NotSubscribed"}).subscribed == "not_subscribed"


@pytest.mark.parametrize("v", V)
def test_me(v):
    raw = fx(f"{v}_account_get")
    me = Me.parse(v, raw["my_user"] if v == "v3" else raw)
    assert me.person.name == "luti_admin" and me.admin
    assert [c.name for c in me.moderates] == ["lutidev"]
    assert me.moderates_id(me.moderates[0].id)


def test_unread_counts():
    assert UnreadCounts.from_v3(fx("v3_unread"), fx("v3_report_count"), 2) == UnreadCounts(0, 1, 2)
    assert UnreadCounts.from_v4(fx("v4_unread")) == UnreadCounts(0, 1, 1)


def test_reports_v3():
    post = Report.from_v3(fx("v3_report_post")["post_reports"][0])
    assert post.kind == "post" and post.reason == "seeded test report" and not post.resolved
    assert post.target_creator.name == "alice" and post.reporter.name == "bob"
    assert post.title == "Welcome to lutidev" and post.post_id and post.community.name == "lutidev"
    com = Report.from_v3(fx("v3_report_comment")["comment_reports"][0])
    assert com.kind == "comment" and com.comment_id and com.content == "bob comment to report"
    assert com.target_creator.name == "bob" and com.reporter.name == "alice"
    pm = Report.from_v3(fx("v3_report_pm")["private_message_reports"][0])
    assert pm.kind == "private_message" and pm.message_id and pm.original == "spammy pm"
    assert pm.target_creator.name == "bob" and pm.community is None


def test_reports_v4():
    reports = {r.kind: r for r in (Report.from_v4(i) for i in fx("v4_report_list_all")["items"])}
    assert set(reports) == {"post", "comment", "private_message"}
    assert reports["post"].target_creator.name == "alice" and reports["post"].reporter.name == "bob"
    assert reports["comment"].content == "bob comment to report" and reports["comment"].post_id
    assert reports["private_message"].original == "spammy pm"
    assert all(r.published.startswith("20") for r in reports.values())


@pytest.mark.parametrize("v", V)
def test_registration_applications(v):
    apps = [RegistrationApplication.parse(v, r) for r in items(v, "admin.registrations", "registrations")]
    carol = next(a for a in apps if a.creator.name == "carol")
    assert carol.status == "pending" and carol.answer == "luti dev seed user" and carol.id


def test_registration_states():
    approved = {"registration_application": {"id": 1, "answer": "a"}, "creator_local_user": {"accepted_application": True},
                "creator": {"id": 2, "name": "x"}}
    denied = {"registration_application": {"id": 1, "answer": "a", "admin_id": 1, "deny_reason": "no"},
              "creator_local_user": {"accepted_application": False}, "creator": {"id": 2, "name": "x"}}
    assert RegistrationApplication.from_v4(approved).status == "approved"
    d = RegistrationApplication.from_v3(denied)
    assert d.status == "denied" and d.deny_reason == "no"


def test_inbox_v3():
    replies = [Notification.from_v3(r, "reply") for r in fx("v3_replies")["replies"]]
    mentions = [Notification.from_v3(r, "mention") for r in fx("v3_mentions")["mentions"]]
    pms = [Notification.from_v3(r, "private_message") for r in fx("v3_pms")["private_messages"]]
    assert any(n.text == "bob replies to alice" and n.creator.name == "bob" for n in replies)
    assert all(n.comment and n.comment.post_id for n in replies + mentions)
    assert mentions and mentions[0].kind == "mention" and "@alice" in mentions[0].text
    assert any(n.message and n.text == "PM from bob" for n in pms)
    # kind can be inferred
    assert Notification.from_v3(fx("v3_replies")["replies"][0]).kind == "reply"
    assert Notification.from_v3(fx("v3_pms")["private_messages"][0]).kind == "private_message"


def test_inbox_v4():
    notes = [Notification.from_v4(r) for r in fx("v4_notifications")["items"]]
    kinds = {n.kind for n in notes}
    assert {"reply", "private_message", "mod_action"} <= kinds
    pm = next(n for n in notes if n.kind == "private_message" and n.text == "PM from bob")
    assert pm.message.creator.name == "bob" and pm.creator.name == "bob"
    reply = next(n for n in notes if n.kind == "reply" and n.text == "bob replies to alice")
    assert reply.comment.post_title == "fixture post"
    mod = next(n for n in notes if n.kind == "mod_action")
    assert mod.summary and mod.text == mod.summary


@pytest.mark.parametrize("v", V)
def test_private_message(v):
    raw = fx("v3_pms")["private_messages"][0] if v == "v3" else next(
        i["data"] for i in fx("v4_notifications")["items"] if i["data"]["type_"] == "private_message")
    pm = PrivateMessage.parse(v, raw)
    assert pm.id and pm.content and pm.creator.name == "bob" and pm.recipient.name == "alice"


def test_modlog_v3():
    entries = [ModlogEntry.from_v3(r) for r in extract_items("modlog", "v3", fx("v3_modlog_full"))]
    actions = {e.action for e in entries}
    assert {"mod_remove_post", "mod_ban_from_community", "mod_add_community"} <= actions
    removal = next(e for e in entries if e.action == "mod_remove_post")
    assert removal.reason == "fixture removal" and removal.target == "bob post for fixtures" and not removal.reverted
    assert removal.moderator.name == "luti_admin" and removal.community.name == "lutidev"
    bans = [e for e in entries if e.action == "mod_ban_from_community" and e.reason == "fixture ban"]
    assert {b.reverted for b in bans} == {True, False}
    assert all(b.target_person.name == "bob" for b in bans)


def test_modlog_v4():
    entries = [ModlogEntry.from_v4(r) for r in fx("v4_modlog_full")["items"]]
    removal = next(e for e in entries if e.action == "mod_remove_post")
    assert removal.target == "bob post for fixtures" and removal.reason == "fixture removal"
    assert "remove post" in removal.description
    bans = [e for e in entries if e.action == "mod_ban_from_community"]
    assert {b.reverted for b in bans} == {True, False}
    assert bans[0].target_person.name == "bob" and bans[0].community.name == "lutidev"


@pytest.mark.parametrize("v", V)
def test_search_results(v):
    from luti_tui.client import extract_items as ex
    results = ex("search", v, fx(f"{v}_search"))
    posts = [Post.parse(v, {k: x for k, x in r.items() if k != "_kind"}) for r in results if r["_kind"] == "post"]
    assert any(p.title == "Welcome to lutidev" for p in posts)


@pytest.mark.parametrize("v", V)
def test_mappers_tolerate_empty(v):
    for cls in (Post, Comment, Community, PrivateMessage, RegistrationApplication, ModlogEntry):
        cls.parse(v, {})
    Report.parse(v, {"post_report": {}})
    Person.parse_view(v, {})
