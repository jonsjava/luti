"""Common data shapes for Lemmy 0.19 (API v3) and 1.0 (API v4) responses.

Every model has `from_v3` / `from_v4` mappers and a `parse(version, raw)`
dispatcher. The main differences handled here:

* v3 `actor_id` / `published` vs v4 `ap_id` / `published_at`
* v3 `counts` objects vs v4 counts stored on the entity itself
* v3 `my_vote` / `saved` / `subscribed` vs the v4 `post_actions`,
  `comment_actions` and `community_actions` objects
* v3 PascalCase enums vs v4 snake_case
"""
from __future__ import annotations

import functools
from dataclasses import dataclass, field
from typing import Any, ClassVar
from urllib.parse import urlparse

from .media import media_kind as _media_kind

Raw = dict[str, Any]


def _d(raw: Any) -> Raw:
    return raw if isinstance(raw, dict) else {}


def _vote_from_int(v: Any) -> str | None:
    if v in (1, "1"):
        return "up"
    if v in (-1, "-1"):
        return "down"
    return None


def _vote_from_bool(v: Any) -> str | None:
    if v is True:
        return "up"
    if v is False:
        return "down"
    return None


def _host(url: str) -> str:
    try:
        return urlparse(url).hostname or ""
    except ValueError:
        return ""


def _when(obj: Raw, *keys: str) -> str:
    for k in keys:
        if obj.get(k):
            return obj[k]
    return ""


class _Model:
    @classmethod
    def parse(cls, version: str, raw: Raw):
        return cls.from_v4(raw) if version == "v4" else cls.from_v3(raw)  # type: ignore[attr-defined]


# --------------------------------------------------------------------------
@dataclass
class Person(_Model):
    id: int
    name: str
    display_name: str | None = None
    ap_id: str = ""
    local: bool = True
    bot: bool = False
    banned: bool = False
    deleted: bool = False
    admin: bool = False
    avatar: str | None = None
    bio: str | None = None
    published: str = ""
    post_count: int | None = None
    comment_count: int | None = None

    @property
    def handle(self) -> str:
        host = _host(self.ap_id)
        return f"{self.name}@{host}" if host and not self.local else self.name

    @property
    def label(self) -> str:
        return self.display_name or self.name

    @classmethod
    def from_v3(cls, p: Raw, *, counts: Raw | None = None, admin: bool = False) -> "Person":
        p = _d(p)
        counts = _d(counts)
        return cls(
            id=p.get("id", 0), name=p.get("name", ""), display_name=p.get("display_name"),
            ap_id=p.get("actor_id", ""), local=p.get("local", True), bot=p.get("bot_account", False),
            banned=p.get("banned", False), deleted=p.get("deleted", False), admin=admin,
            avatar=p.get("avatar"), bio=p.get("bio"), published=p.get("published", ""),
            post_count=counts.get("post_count"), comment_count=counts.get("comment_count"),
        )

    @classmethod
    def from_v4(cls, p: Raw, *, banned: bool = False, admin: bool = False) -> "Person":
        p = _d(p)
        return cls(
            id=p.get("id", 0), name=p.get("name", ""), display_name=p.get("display_name"),
            ap_id=p.get("ap_id", ""), local=p.get("local", True), bot=p.get("bot_account", False),
            banned=banned, deleted=p.get("deleted", False), admin=admin,
            avatar=p.get("avatar"), bio=p.get("bio"), published=p.get("published_at", ""),
            post_count=p.get("post_count"), comment_count=p.get("comment_count"),
        )

    @classmethod
    def from_view_v3(cls, view: Raw) -> "Person":
        """A PersonView ({person, counts, is_admin})."""
        view = _d(view)
        return cls.from_v3(view.get("person"), counts=view.get("counts"), admin=view.get("is_admin", False))

    @classmethod
    def from_view_v4(cls, view: Raw) -> "Person":
        view = _d(view)
        return cls.from_v4(view.get("person"), banned=view.get("banned", False), admin=view.get("is_admin", False))

    @classmethod
    def parse_view(cls, version: str, view: Raw) -> "Person":
        """A PersonView; `.raw` is the whole view."""
        person = cls.from_view_v4(view) if version == "v4" else cls.from_view_v3(view)
        person.raw = view
        return person


# --------------------------------------------------------------------------
@dataclass
class Community(_Model):
    id: int
    name: str
    title: str = ""
    description: str | None = None
    ap_id: str = ""
    local: bool = True
    nsfw: bool = False
    removed: bool = False
    deleted: bool = False
    subscribers: int | None = None
    posts: int | None = None
    comments: int | None = None
    subscribed: str = "not_subscribed"  # not_subscribed / subscribed / pending
    blocked: bool = False
    is_moderator: bool = False
    published: str = ""

    @property
    def handle(self) -> str:
        host = _host(self.ap_id)
        return f"!{self.name}@{host}" if host and not self.local else f"!{self.name}"

    @property
    def is_subscribed(self) -> bool:
        return self.subscribed in ("subscribed", "pending")

    @classmethod
    def from_v3(cls, view: Raw) -> "Community":
        """CommunityView, or anything carrying `community` (+ `subscribed`)."""
        view = _d(view)
        c = _d(view.get("community")) or view
        counts = _d(view.get("counts"))
        sub = view.get("subscribed") or "NotSubscribed"
        return cls(
            id=c.get("id", 0), name=c.get("name", ""), title=c.get("title", ""),
            description=c.get("description"), ap_id=c.get("actor_id", ""), local=c.get("local", True),
            nsfw=c.get("nsfw", False), removed=c.get("removed", False), deleted=c.get("deleted", False),
            subscribers=counts.get("subscribers"), posts=counts.get("posts"), comments=counts.get("comments"),
            subscribed=_sub_state_v3(sub), blocked=view.get("blocked", False),
            published=c.get("published", ""),
        )

    @classmethod
    def from_v4(cls, view: Raw) -> "Community":
        view = _d(view)
        c = _d(view.get("community")) or view
        actions = _d(view.get("community_actions"))
        follow = actions.get("follow_state")
        sub = {"accepted": "subscribed", "pending": "pending", "approval_required": "pending"}.get(follow or "", "not_subscribed")
        return cls(
            id=c.get("id", 0), name=c.get("name", ""), title=c.get("title", ""),
            description=c.get("description") or c.get("sidebar"), ap_id=c.get("ap_id", ""),
            local=c.get("local", True), nsfw=c.get("nsfw", False), removed=c.get("removed", False),
            deleted=c.get("deleted", False), subscribers=c.get("subscribers"), posts=c.get("posts"),
            comments=c.get("comments"), subscribed=sub, blocked=bool(actions.get("blocked_at")),
            is_moderator=bool(actions.get("became_moderator_at")),
            published=c.get("published_at", ""),
        )


def _sub_state_v3(sub: str) -> str:
    return {"Subscribed": "subscribed", "Pending": "pending", "ApprovalRequired": "pending"}.get(sub, "not_subscribed")


# --------------------------------------------------------------------------
@dataclass
class Post(_Model):
    id: int
    title: str
    body: str | None = None
    url: str | None = None
    community: Community | None = None
    creator: Person | None = None
    score: int = 0
    upvotes: int = 0
    downvotes: int = 0
    comments: int = 0
    published: str = ""
    my_vote: str | None = None  # "up" / "down" / None
    saved: bool = False
    read: bool = False
    locked: bool = False
    featured: bool = False
    removed: bool = False
    deleted: bool = False
    nsfw: bool = False
    ap_id: str = ""
    creator_is_moderator: bool = False
    creator_is_admin: bool = False
    creator_banned_from_community: bool = False
    url_content_type: str | None = None
    thumbnail_url: str | None = None
    embed_video_url: str | None = None
    embed_title: str | None = None
    alt_text: str | None = None

    @property
    def media_kind(self) -> str:
        """image / video / link / none (from the server's data; no network)."""
        return _media_kind(self.url, self.url_content_type, self.embed_video_url)

    @classmethod
    def from_v3(cls, view: Raw) -> "Post":
        view = _d(view)
        p = _d(view.get("post"))
        counts = _d(view.get("counts"))
        return cls(
            id=p.get("id", 0), title=p.get("name", ""), body=p.get("body"), url=p.get("url"),
            community=Community.from_v3({"community": view.get("community"), "subscribed": view.get("subscribed")}) if view.get("community") else None,
            creator=Person.from_v3(view.get("creator")) if view.get("creator") else None,
            score=counts.get("score", 0), upvotes=counts.get("upvotes", 0), downvotes=counts.get("downvotes", 0),
            comments=counts.get("comments", 0), published=p.get("published", ""),
            my_vote=_vote_from_int(view.get("my_vote")), saved=bool(view.get("saved")), read=bool(view.get("read")),
            locked=p.get("locked", False), featured=p.get("featured_community", False) or p.get("featured_local", False),
            removed=p.get("removed", False), deleted=p.get("deleted", False), nsfw=p.get("nsfw", False),
            ap_id=p.get("ap_id", ""), creator_is_moderator=view.get("creator_is_moderator", False),
            creator_is_admin=view.get("creator_is_admin", False),
            creator_banned_from_community=view.get("creator_banned_from_community", False),
            **_post_media(p),
        )

    @classmethod
    def from_v4(cls, view: Raw) -> "Post":
        view = _d(view)
        p = _d(view.get("post"))
        actions = _d(view.get("post_actions"))
        community = None
        if view.get("community"):
            community = Community.from_v4({"community": view.get("community"), "community_actions": view.get("community_actions")})
        return cls(
            id=p.get("id", 0), title=p.get("name", ""), body=p.get("body"), url=p.get("url"),
            community=community,
            creator=Person.from_v4(view.get("creator"), banned=view.get("creator_banned", False)) if view.get("creator") else None,
            score=p.get("score", 0), upvotes=p.get("upvotes", 0), downvotes=p.get("downvotes", 0),
            comments=p.get("comments", 0), published=p.get("published_at", ""),
            my_vote=_vote_from_bool(actions.get("vote_is_upvote")), saved=bool(actions.get("saved_at")),
            read=bool(actions.get("read_at")), locked=p.get("locked", False),
            featured=p.get("featured_community", False) or p.get("featured_local", False),
            removed=p.get("removed", False), deleted=p.get("deleted", False), nsfw=p.get("nsfw", False),
            ap_id=p.get("ap_id", ""), creator_is_moderator=view.get("creator_is_moderator", False),
            creator_is_admin=view.get("creator_is_admin", False),
            creator_banned_from_community=view.get("creator_banned_from_community", False),
            **_post_media(p),
        )


def _post_media(p: Raw) -> dict[str, Any]:
    return {k: p.get(k) for k in ("url_content_type", "thumbnail_url", "embed_video_url", "embed_title", "alt_text")}


# --------------------------------------------------------------------------
@dataclass
class Comment(_Model):
    id: int
    post_id: int
    content: str
    path: str = "0"
    creator: Person | None = None
    post_title: str = ""
    community: Community | None = None
    score: int = 0
    upvotes: int = 0
    downvotes: int = 0
    child_count: int = 0
    published: str = ""
    my_vote: str | None = None
    saved: bool = False
    removed: bool = False
    deleted: bool = False
    distinguished: bool = False
    ap_id: str = ""
    creator_is_moderator: bool = False
    creator_is_admin: bool = False
    creator_banned_from_community: bool = False

    @property
    def parent_id(self) -> int | None:
        parts = self.path.split(".")
        return int(parts[-2]) if len(parts) > 2 else None

    @property
    def depth(self) -> int:
        return max(0, len(self.path.split(".")) - 2)

    @classmethod
    def from_v3(cls, view: Raw) -> "Comment":
        view = _d(view)
        c = _d(view.get("comment"))
        counts = _d(view.get("counts"))
        return cls(
            id=c.get("id", 0), post_id=c.get("post_id", 0), content=c.get("content", ""), path=c.get("path", "0"),
            creator=Person.from_v3(view.get("creator")) if view.get("creator") else None,
            post_title=_d(view.get("post")).get("name", ""),
            community=Community.from_v3({"community": view.get("community"), "subscribed": view.get("subscribed")}) if view.get("community") else None,
            score=counts.get("score", 0), upvotes=counts.get("upvotes", 0), downvotes=counts.get("downvotes", 0),
            child_count=counts.get("child_count", 0), published=c.get("published", ""),
            my_vote=_vote_from_int(view.get("my_vote")), saved=bool(view.get("saved")),
            removed=c.get("removed", False), deleted=c.get("deleted", False), distinguished=c.get("distinguished", False),
            ap_id=c.get("ap_id", ""), creator_is_moderator=view.get("creator_is_moderator", False),
            creator_is_admin=view.get("creator_is_admin", False),
            creator_banned_from_community=view.get("creator_banned_from_community", False),
        )

    @classmethod
    def from_v4(cls, view: Raw) -> "Comment":
        view = _d(view)
        c = _d(view.get("comment"))
        actions = _d(view.get("comment_actions"))
        return cls(
            id=c.get("id", 0), post_id=c.get("post_id", 0), content=c.get("content", ""), path=c.get("path", "0"),
            creator=Person.from_v4(view.get("creator"), banned=view.get("creator_banned", False)) if view.get("creator") else None,
            post_title=_d(view.get("post")).get("name", ""),
            community=Community.from_v4({"community": view.get("community"), "community_actions": view.get("community_actions")}) if view.get("community") else None,
            score=c.get("score", 0), upvotes=c.get("upvotes", 0), downvotes=c.get("downvotes", 0),
            child_count=c.get("child_count", 0), published=c.get("published_at", ""),
            my_vote=_vote_from_bool(actions.get("vote_is_upvote")), saved=bool(actions.get("saved_at")),
            removed=c.get("removed", False), deleted=c.get("deleted", False), distinguished=c.get("distinguished", False),
            ap_id=c.get("ap_id", ""), creator_is_moderator=view.get("creator_is_moderator", False),
            creator_is_admin=view.get("creator_is_admin", False),
            creator_banned_from_community=view.get("creator_banned_from_community", False),
        )


@dataclass
class CommentNode:
    comment: Comment
    children: list["CommentNode"] = field(default_factory=list)


def build_comment_tree(comments: list[Comment]) -> list[CommentNode]:
    """Arrange a flat comment list into a tree using each comment's path."""
    nodes = {c.id: CommentNode(c) for c in comments}
    roots: list[CommentNode] = []
    for c in comments:
        parent = c.parent_id
        if parent is not None and parent in nodes:
            nodes[parent].children.append(nodes[c.id])
        else:
            roots.append(nodes[c.id])
    return roots


# --------------------------------------------------------------------------
@dataclass
class PrivateMessage(_Model):
    id: int
    content: str
    creator: Person | None = None
    recipient: Person | None = None
    read: bool = False
    published: str = ""
    deleted: bool = False

    @classmethod
    def from_v3(cls, view: Raw) -> "PrivateMessage":
        view = _d(view)
        m = _d(view.get("private_message"))
        return cls(
            id=m.get("id", 0), content=m.get("content", ""),
            creator=Person.from_v3(view.get("creator")) if view.get("creator") else None,
            recipient=Person.from_v3(view.get("recipient")) if view.get("recipient") else None,
            read=m.get("read", False), published=m.get("published", ""), deleted=m.get("deleted", False),
        )

    @classmethod
    def from_v4(cls, view: Raw, *, read: bool = False) -> "PrivateMessage":
        view = _d(view)
        m = _d(view.get("private_message"))
        return cls(
            id=m.get("id", 0), content=m.get("content", ""),
            creator=Person.from_v4(view.get("creator")) if view.get("creator") else None,
            recipient=Person.from_v4(view.get("recipient")) if view.get("recipient") else None,
            read=m.get("read", read), published=m.get("published_at", ""), deleted=m.get("deleted", False),
        )


# --------------------------------------------------------------------------
@dataclass
class Notification(_Model):
    """One inbox entry: a reply, a mention, a private message or (v4) a mod action."""

    id: int  # v4 notification id; v3 comment_reply / person_mention / private_message id
    kind: str  # reply / mention / private_message / mod_action / post / ...
    read: bool = False
    published: str = ""
    creator: Person | None = None
    comment: Comment | None = None
    message: PrivateMessage | None = None
    summary: str = ""

    @property
    def text(self) -> str:
        if self.comment:
            return self.comment.content
        if self.message:
            return self.message.content
        return self.summary

    @classmethod
    def from_v3(cls, raw: Raw, kind: str | None = None) -> "Notification":
        raw = _d(raw)
        if kind is None:
            kind = "reply" if "comment_reply" in raw else "mention" if "person_mention" in raw else "private_message"
        if kind == "private_message":
            pm = PrivateMessage.from_v3(raw)
            return cls(id=pm.id, kind=kind, read=pm.read, published=pm.published, creator=pm.creator, message=pm)
        meta = _d(raw.get("comment_reply") or raw.get("person_mention"))
        comment = Comment.from_v3(raw)
        return cls(id=meta.get("id", 0), kind=kind, read=meta.get("read", False),
                   published=meta.get("published", comment.published), creator=comment.creator, comment=comment)

    @classmethod
    def from_v4(cls, raw: Raw) -> "Notification":
        raw = _d(raw)
        n = _d(raw.get("notification"))
        data = _d(raw.get("data"))
        kind = n.get("kind") or data.get("type_", "")
        read = n.get("read", False)
        note = cls(id=n.get("id", 0), kind=kind, read=read, published=n.get("published_at", ""))
        dtype = data.get("type_")
        if dtype == "comment":
            note.comment = Comment.from_v4(data)
            note.creator = note.comment.creator
        elif dtype == "private_message":
            note.message = PrivateMessage.from_v4(data, read=read)
            note.creator = note.message.creator
        elif dtype == "post":
            post = Post.from_v4(data)
            note.creator = post.creator
            note.summary = post.title
        elif dtype == "mod_action":
            entry = ModlogEntry.from_v4(data)
            note.creator = entry.moderator
            note.summary = entry.description
        return note


# --------------------------------------------------------------------------
@dataclass
class Report(_Model):
    kind: str  # post / comment / private_message
    id: int
    reason: str
    resolved: bool = False
    published: str = ""
    reporter: Person | None = None
    target_creator: Person | None = None
    community: Community | None = None
    post_id: int | None = None
    comment_id: int | None = None
    message_id: int | None = None
    title: str = ""  # post title (post and comment reports)
    content: str = ""  # current text of the reported item
    original: str = ""  # text as it was when reported
    target_removed: bool = False

    @classmethod
    def from_v3(cls, raw: Raw, kind: str | None = None) -> "Report":
        raw = _d(raw)
        kind = kind or ("post" if "post_report" in raw else "comment" if "comment_report" in raw else "private_message")
        return cls._build(kind, raw, Person.from_v3, Community.from_v3, "published")

    @classmethod
    def from_v4(cls, raw: Raw) -> "Report":
        raw = _d(raw)
        kind = raw.get("type_") or ("post" if "post_report" in raw else "comment" if "comment_report" in raw else "private_message")
        return cls._build(kind, raw, Person.from_v4, Community.from_v4, "published_at")

    @classmethod
    def _build(cls, kind: str, raw: Raw, person, community, when_key: str) -> "Report":
        rep = _d(raw.get(f"{kind}_report"))
        r = cls(kind=kind, id=rep.get("id", 0), reason=rep.get("reason", ""), resolved=rep.get("resolved", False),
                published=rep.get(when_key, ""))
        if raw.get("creator"):
            r.reporter = person(raw["creator"])
        if raw.get("community"):
            r.community = community({"community": raw["community"]})
        post = _d(raw.get("post"))
        if kind == "post":
            r.post_id = rep.get("post_id")
            r.title = post.get("name", "")
            r.content = post.get("body") or post.get("url") or ""
            r.original = rep.get("original_post_name", "")
            if rep.get("original_post_body"):
                r.original += "\n\n" + rep["original_post_body"]
            r.target_removed = post.get("removed", False)
            if raw.get("post_creator"):
                r.target_creator = person(raw["post_creator"])
        elif kind == "comment":
            c = _d(raw.get("comment"))
            r.comment_id = rep.get("comment_id")
            r.post_id = c.get("post_id") or post.get("id")
            r.title = post.get("name", "")
            r.content = c.get("content", "")
            r.original = rep.get("original_comment_text", "")
            r.target_removed = c.get("removed", False)
            if raw.get("comment_creator"):
                r.target_creator = person(raw["comment_creator"])
        else:
            m = _d(raw.get("private_message"))
            r.message_id = rep.get("private_message_id")
            r.content = m.get("content", "")
            r.original = rep.get("original_pm_text", "")
            r.target_removed = m.get("removed", False)
            if raw.get("private_message_creator"):
                r.target_creator = person(raw["private_message_creator"])
        return r


# --------------------------------------------------------------------------
@dataclass
class RegistrationApplication(_Model):
    id: int
    answer: str
    creator: Person | None = None
    published: str = ""
    email: str | None = None
    status: str = "pending"  # pending / approved / denied
    deny_reason: str | None = None
    admin: Person | None = None

    @classmethod
    def from_v3(cls, raw: Raw) -> "RegistrationApplication":
        return cls._build(_d(raw), Person.from_v3, "published")

    @classmethod
    def from_v4(cls, raw: Raw) -> "RegistrationApplication":
        return cls._build(_d(raw), Person.from_v4, "published_at")

    @classmethod
    def _build(cls, raw: Raw, person, when_key: str) -> "RegistrationApplication":
        ra = _d(raw.get("registration_application"))
        lu = _d(raw.get("creator_local_user"))
        if lu.get("accepted_application"):
            status = "approved"
        elif ra.get("admin_id") or ra.get("deny_reason"):
            status = "denied"
        else:
            status = "pending"
        return cls(
            id=ra.get("id", 0), answer=ra.get("answer", ""),
            creator=person(raw["creator"]) if raw.get("creator") else None,
            published=ra.get(when_key, ""), email=lu.get("email"), status=status,
            deny_reason=ra.get("deny_reason"), admin=person(raw["admin"]) if raw.get("admin") else None,
        )


# --------------------------------------------------------------------------
@dataclass
class ModlogEntry(_Model):
    action: str  # snake_case, e.g. mod_remove_post / mod_ban_from_community
    when: str = ""
    moderator: Person | None = None
    reason: str | None = None
    reverted: bool = False  # unban / restore / unlock / remove mod ...
    target_person: Person | None = None
    community: Community | None = None
    target: str = ""  # post title / comment text / community name

    # v3 action table: _kind list key -> (detail key, person key, revert flag field, revert when)
    _V3: ClassVar[dict[str, tuple[str, str | None, str | None, Any]]] = {
        "removed_posts": ("mod_remove_post", None, "removed", False),
        "locked_posts": ("mod_lock_post", None, "locked", False),
        "featured_posts": ("mod_feature_post", None, "featured", False),
        "removed_comments": ("mod_remove_comment", "commenter", "removed", False),
        "removed_communities": ("mod_remove_community", None, "removed", False),
        "banned_from_community": ("mod_ban_from_community", "banned_person", "banned", False),
        "banned": ("mod_ban", "banned_person", "banned", False),
        "added_to_community": ("mod_add_community", "modded_person", "removed", True),
        "transferred_to_community": ("mod_transfer_community", "modded_person", None, None),
        "added": ("mod_add", "modded_person", "removed", True),
        "admin_purged_persons": ("admin_purge_person", None, None, None),
        "admin_purged_communities": ("admin_purge_community", None, None, None),
        "admin_purged_posts": ("admin_purge_post", None, None, None),
        "admin_purged_comments": ("admin_purge_comment", None, None, None),
        "hidden_communities": ("mod_hide_community", None, "hidden", False),
    }

    @property
    def description(self) -> str:
        verb = self.action.replace("mod_", "").replace("admin_", "").replace("_", " ")
        if self.reverted:
            verb = f"undo {verb}"
        parts = [verb]
        if self.target_person:
            parts.append(self.target_person.name)
        if self.target:
            parts.append(f"“{self.target[:60]}”")
        if self.community:
            parts.append(f"in !{self.community.name}")
        return " ".join(parts)

    @classmethod
    def from_v3(cls, raw: Raw) -> "ModlogEntry":
        raw = _d(raw)
        key = raw.get("_kind", "")
        detail_key, person_key, flag, revert_when = cls._V3.get(key, (key, None, None, None))
        detail = _d(raw.get(detail_key))
        if not detail:  # unknown: take the first dict that has when_
            detail = next((v for v in raw.values() if isinstance(v, dict) and "when_" in v), {})
        reverted = flag is not None and detail.get(flag) == revert_when
        target = _d(raw.get("post")).get("name") or _d(raw.get("comment")).get("content") or ""
        return cls(
            action=detail_key, when=detail.get("when_", ""),
            moderator=Person.from_v3(raw["moderator"]) if raw.get("moderator") else None,
            reason=detail.get("reason"), reverted=reverted,
            target_person=Person.from_v3(raw[person_key]) if person_key and raw.get(person_key) else None,
            community=Community.from_v3({"community": raw["community"]}) if raw.get("community") else None,
            target=target,
        )

    @classmethod
    def from_v4(cls, raw: Raw) -> "ModlogEntry":
        raw = _d(raw)
        m = _d(raw.get("modlog"))
        target = _d(raw.get("target_post")).get("name") or _d(raw.get("target_comment")).get("content") or ""
        return cls(
            action=m.get("kind", ""), when=m.get("published_at", ""),
            moderator=Person.from_v4(raw["moderator"]) if raw.get("moderator") else None,
            reason=m.get("reason"), reverted=bool(m.get("is_revert")),
            target_person=Person.from_v4(raw["target_person"]) if raw.get("target_person") else None,
            community=Community.from_v4({"community": raw["target_community"]}) if raw.get("target_community") else None,
            target=target,
        )


# --------------------------------------------------------------------------
@dataclass
class Me:
    person: Person
    admin: bool = False
    moderates: list[Community] = field(default_factory=list)
    follows: list[Community] = field(default_factory=list)
    show_nsfw: bool = False
    blur_nsfw: bool = True

    @classmethod
    def from_v3(cls, my_user: Raw) -> "Me":
        my_user = _d(my_user)
        luv = _d(my_user.get("local_user_view"))
        lu = _d(luv.get("local_user"))
        admin = bool(lu.get("admin"))
        return cls(
            show_nsfw=bool(lu.get("show_nsfw", False)), blur_nsfw=bool(lu.get("blur_nsfw", True)),
            person=Person.from_v3(luv.get("person"), counts=luv.get("counts"), admin=admin), admin=admin,
            moderates=[Community.from_v3({"community": m.get("community")}) for m in my_user.get("moderates") or []],
            follows=[Community.from_v3({"community": f.get("community"), "subscribed": "Subscribed"}) for f in my_user.get("follows") or []],
        )

    @classmethod
    def from_v4(cls, account: Raw) -> "Me":
        account = _d(account)
        luv = _d(account.get("local_user_view"))
        lu = _d(luv.get("local_user"))
        admin = bool(lu.get("admin"))
        return cls(
            show_nsfw=bool(lu.get("show_nsfw", False)), blur_nsfw=bool(lu.get("blur_nsfw", True)),
            person=Person.from_v4(luv.get("person"), banned=luv.get("banned", False), admin=admin), admin=admin,
            moderates=[Community.from_v4({"community": m.get("community")}) for m in account.get("moderates") or []],
            follows=[Community.from_v4({"community": f.get("community"), "community_actions": {"follow_state": "accepted"}})
                     for f in account.get("follows") or []],
        )

    @classmethod
    def parse(cls, version: str, raw: Raw) -> "Me":
        return cls.from_v4(raw) if version == "v4" else cls.from_v3(raw)

    def moderates_id(self, community_id: int | None) -> bool:
        return any(c.id == community_id for c in self.moderates)


@dataclass
class UnreadCounts:
    inbox: int = 0  # replies + mentions + PMs (v3) / notification_count (v4)
    reports: int = 0
    applications: int = 0

    @classmethod
    def from_v3(cls, unread: Raw, reports: Raw | None = None, applications: int = 0) -> "UnreadCounts":
        unread, reports = _d(unread), _d(reports)
        return cls(
            inbox=sum(unread.get(k, 0) or 0 for k in ("replies", "mentions", "private_messages")),
            reports=sum(reports.get(k, 0) or 0 for k in ("post_reports", "comment_reports", "private_message_reports")),
            applications=applications,
        )

    @classmethod
    def from_v4(cls, unread: Raw) -> "UnreadCounts":
        unread = _d(unread)
        return cls(inbox=unread.get("notification_count", 0) or 0, reports=unread.get("report_count", 0) or 0,
                   applications=unread.get("registration_application_count", 0) or 0)


# --------------------------------------------------------------------------
# Every model keeps the response object it was built from in `.raw`, for
# callers who need fields luti doesn't map.
def _keep_raw(fn):
    @functools.wraps(fn)
    def wrapper(cls, raw, *args, **kwargs):
        obj = fn.__func__(cls, raw, *args, **kwargs)
        if getattr(obj, "raw", None) is None:
            obj.raw = raw
        return obj
    return classmethod(wrapper)


for _cls in (Person, Community, Post, Comment, PrivateMessage, Notification, Report,
             RegistrationApplication, ModlogEntry, Me):
    _cls.raw = None  # type: ignore[attr-defined]
    _cls.__annotations__["raw"] = "Raw | None"
    for _name in ("from_v3", "from_v4"):
        setattr(_cls, _name, _keep_raw(_cls.__dict__[_name]))
del _cls, _name
