"""High-level, version-agnostic Lemmy operations returning luti models.

Screens talk to `Lemmy`; it calls `LemmyClient.call` with canonical params
and maps responses with the models' v3/v4 mappers.
"""
from __future__ import annotations

import time
from typing import Any, Callable, Generic, TypeVar

from .client import LemmyClient, Pager, UnsupportedOp
from .models import (
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
)

T = TypeVar("T")
NO_REASON = "No reason given"

POST_SORTS = ["active", "hot", "new", "old", "top", "most_comments", "new_comments", "controversial", "scaled"]
COMMENT_SORTS = ["hot", "top", "new", "old", "controversial"]
LISTING_TYPES = ["all", "local", "subscribed", "moderator_view"]
TIME_RANGES = ["hour", "six_hour", "twelve_hour", "day", "week", "month", "three_months",
               "six_months", "nine_months", "year", "all"]
SEARCH_TYPES = ["all", "posts", "comments", "communities", "users"]


class ModelPager(Generic[T]):
    """A Pager whose pages come back as models."""

    def __init__(self, pager: Pager, mapper: Callable[[dict], T]):
        self._pager = pager
        self._mapper = mapper

    @property
    def has_more(self) -> bool:
        return self._pager.has_more

    async def next_page(self) -> list[T]:
        return [self._mapper(raw) for raw in await self._pager.next_page()]


def _expires(days: float | None) -> int | None:
    return int(time.time() + days * 86400) if days else None


class Lemmy:
    def __init__(self, client: LemmyClient):
        self.client = client
        self.me: Me | None = None

    @property
    def version(self) -> str:
        assert self.client.version, "not connected"
        return self.client.version

    @property
    def is_v4(self) -> bool:
        return self.version == "v4"

    async def connect(self) -> str:
        return await self.client.detect()

    async def aclose(self) -> None:
        await self.client.aclose()

    def _pager(self, op: str, mapper: Callable[[dict], T], limit: int = 20, **params: Any) -> ModelPager[T]:
        return ModelPager(self.client.pager(op, limit, **params), mapper)

    # -- account -------------------------------------------------------------
    async def login(self, username: str, password: str, totp: str | None = None) -> str:
        await self.connect()
        return await self.client.login(username, password, totp)

    async def logout(self) -> None:
        try:
            await self.client.call("auth.logout")
        finally:
            self.client.token = None
            self.me = None

    async def load_me(self) -> Me | None:
        if not self.client.token:
            self.me = None
            return None
        raw = await self.client.call("account.get")
        self.me = Me.parse(self.version, raw) if raw else None
        return self.me

    @property
    def is_admin(self) -> bool:
        return bool(self.me and self.me.admin)

    @property
    def is_mod(self) -> bool:
        return bool(self.me and (self.me.admin or self.me.moderates))

    async def unread(self) -> UnreadCounts:
        if self.is_v4:
            return UnreadCounts.from_v4(await self.client.call("unread.counts"))
        unread = await self.client.call("unread.counts")
        reports = await self.client.call("report.count") if self.is_mod else {}
        apps = 0
        if self.is_admin:
            apps = len(await self.registrations(unread_only=True))
        return UnreadCounts.from_v3(unread, reports, apps)

    # -- posts -----------------------------------------------------------------
    def posts(self, sort: str = "active", time_range: str | None = None, listing_type: str | None = None,
              community_id: int | None = None, community_name: str | None = None,
              saved_only: bool | None = None, limit: int = 20) -> ModelPager[Post]:
        params: dict[str, Any] = {"sort": sort, "type_": listing_type, "community_id": community_id,
                                  "community_name": community_name, "saved_only": saved_only}
        if sort == "top":
            params["time_range"] = time_range
        return self._pager("post.list", lambda r: Post.parse(self.version, r), limit, **params)

    async def post(self, post_id: int) -> Post:
        data = await self.client.call("post.get", id=post_id)
        return Post.parse(self.version, data["post_view"])

    async def create_post(self, community_id: int, title: str, body: str | None = None, url: str | None = None,
                          nsfw: bool | None = None) -> Post:
        data = await self.client.call("post.create", community_id=community_id, name=title, body=body or None,
                                      url=url or None, nsfw=nsfw)
        return Post.parse(self.version, data["post_view"])

    async def vote_post(self, post_id: int, vote: str) -> Post:
        data = await self.client.call("post.vote", post_id=post_id, vote=vote)
        return Post.parse(self.version, data["post_view"])

    async def save_post(self, post_id: int, save: bool) -> Post:
        data = await self.client.call("post.save", post_id=post_id, save=save)
        return Post.parse(self.version, data["post_view"])

    async def remove_post(self, post_id: int, removed: bool = True, reason: str | None = None) -> Post:
        data = await self.client.call("post.remove", post_id=post_id, removed=removed, reason=reason or NO_REASON)
        return Post.parse(self.version, data["post_view"])

    async def delete_post(self, post_id: int, deleted: bool = True) -> None:
        await self.client.call("post.delete", post_id=post_id, deleted=deleted)

    async def report_post(self, post_id: int, reason: str) -> None:
        await self.client.call("post.report", post_id=post_id, reason=reason)

    # -- comments --------------------------------------------------------------
    async def comments(self, post_id: int, sort: str = "hot", max_depth: int = 8, max_items: int = 500) -> list[Comment]:
        pager = self.client.pager("comment.list", 50, post_id=post_id, sort=sort, max_depth=max_depth, type_="all")
        out: list[Comment] = []
        seen: set[int] = set()
        while pager.has_more and len(out) < max_items:
            fresh = [c for c in (Comment.parse(self.version, r) for r in await pager.next_page()) if c.id not in seen]
            if not fresh:  # v3 ignores paging when max_depth is set and repeats the page
                break
            seen.update(c.id for c in fresh)
            out.extend(fresh)
        return out

    async def create_comment(self, post_id: int, content: str, parent_id: int | None = None) -> Comment:
        data = await self.client.call("comment.create", post_id=post_id, content=content, parent_id=parent_id)
        return Comment.parse(self.version, data["comment_view"])

    async def vote_comment(self, comment_id: int, vote: str) -> Comment:
        data = await self.client.call("comment.vote", comment_id=comment_id, vote=vote)
        return Comment.parse(self.version, data["comment_view"])

    async def save_comment(self, comment_id: int, save: bool) -> Comment:
        data = await self.client.call("comment.save", comment_id=comment_id, save=save)
        return Comment.parse(self.version, data["comment_view"])

    async def remove_comment(self, comment_id: int, removed: bool = True, reason: str | None = None) -> Comment:
        data = await self.client.call("comment.remove", comment_id=comment_id, removed=removed, reason=reason or NO_REASON)
        return Comment.parse(self.version, data["comment_view"])

    async def report_comment(self, comment_id: int, reason: str) -> None:
        await self.client.call("comment.report", comment_id=comment_id, reason=reason)

    # -- private messages ------------------------------------------------------
    async def send_pm(self, recipient_id: int, content: str) -> PrivateMessage:
        data = await self.client.call("pm.create", recipient_id=recipient_id, content=content)
        return PrivateMessage.parse(self.version, data["private_message_view"])

    # -- inbox -------------------------------------------------------------------
    async def inbox(self, unread_only: bool = False, limit: int = 50) -> list[Notification]:
        if self.is_v4:
            pager = self.client.pager("notifications.list", limit, unread_only=unread_only)
            return [Notification.from_v4(r) for r in await pager.next_page()]
        out: list[Notification] = []
        for op, kind in (("inbox.replies", "reply"), ("inbox.mentions", "mention"), ("pm.list", "private_message")):
            params: dict[str, Any] = {"unread_only": unread_only}
            if op != "pm.list":
                params["sort"] = "new"
            pager = self.client.pager(op, limit, **params)
            for raw in await pager.next_page():
                n = Notification.from_v3(raw, kind)
                if kind == "private_message" and self.me and n.creator and n.creator.id == self.me.person.id:
                    continue  # v3 lists sent messages too
                out.append(n)
        out.sort(key=lambda n: n.published, reverse=True)
        return out

    async def mark_read(self, note: Notification) -> None:
        if self.is_v4:
            await self.client.call("notifications.read", notification_id=note.id, read=True)
        else:
            raise UnsupportedOp("notifications.read", "v3")

    async def mark_all_read(self) -> None:
        await self.client.call("inbox.mark_all_read")

    # -- communities -----------------------------------------------------------
    def communities(self, listing_type: str = "all", sort: str = "hot", limit: int = 30) -> ModelPager[Community]:
        return self._pager("community.list", lambda r: Community.parse(self.version, r), limit,
                           type_=listing_type, sort=sort)

    async def community(self, name: str | None = None, community_id: int | None = None) -> Community:
        data = await self.client.call("community.get", name=name, id=community_id)
        return Community.parse(self.version, data["community_view"])

    async def follow(self, community_id: int, follow: bool) -> Community:
        data = await self.client.call("community.follow", community_id=community_id, follow=follow)
        return Community.parse(self.version, data["community_view"])

    async def ban_from_community(self, community_id: int, person_id: int, ban: bool, reason: str | None = None,
                                 remove_data: bool = False, expires_days: float | None = None) -> None:
        await self.client.call("community.ban", community_id=community_id, person_id=person_id, ban=ban,
                               reason=reason or NO_REASON, remove_or_restore_data=remove_data or None,
                               expires_at=_expires(expires_days) if ban else None)

    # -- people ------------------------------------------------------------------
    async def person(self, username: str | None = None, person_id: int | None = None) -> tuple[Person, list[Post | Comment]]:
        data = await self.client.call("person.get", username=username, person_id=person_id)
        person = Person.parse_view(self.version, data["person_view"])
        if self.is_v4:
            content = await self.client.call("person.content", person_id=person.id, limit=30)
            items = self.client.items("person.content", content)
        else:
            items = self.client.items("person.content", data)
        out: list[Post | Comment] = [
            (Comment if "comment" in raw else Post).parse(self.version, raw) for raw in items
        ]
        out.sort(key=lambda x: x.published, reverse=True)
        return person, out

    async def find_person(self, username: str) -> Person:
        data = await self.client.call("person.get", username=username)
        return Person.parse_view(self.version, data["person_view"])

    async def ban_site(self, person_id: int, ban: bool, reason: str | None = None, remove_data: bool = False,
                       expires_days: float | None = None) -> None:
        await self.client.call("admin.ban", person_id=person_id, ban=ban, reason=reason or NO_REASON,
                               remove_or_restore_data=remove_data or None,
                               expires_at=_expires(expires_days) if ban else None)

    # -- search --------------------------------------------------------------------
    async def search(self, query: str, type_: str = "all", listing_type: str = "all", limit: int = 20) -> list[Any]:
        data = await self.client.call("search", search_term=query, type_=type_, listing_type=listing_type, limit=limit)
        out: list[Any] = []
        for raw in self.client.items("search", data):
            kind = raw.pop("_kind", None)
            if kind == "post":
                out.append(Post.parse(self.version, raw))
            elif kind == "comment":
                out.append(Comment.parse(self.version, raw))
            elif kind == "community":
                out.append(Community.parse(self.version, raw))
            elif kind == "person":
                out.append(Person.parse_view(self.version, raw))
        return out

    # -- moderation ------------------------------------------------------------------
    async def reports(self, unresolved_only: bool = True, community_id: int | None = None) -> list[Report]:
        ops = ["report.list.post", "report.list.comment"]
        if self.is_admin:
            ops.append("report.list.pm")
        out: list[Report] = []
        for op in ops:
            params: dict[str, Any] = {"unresolved_only": unresolved_only}
            if op != "report.list.pm":
                params["community_id"] = community_id
            for raw in await self.client.pager(op, 50, **params).next_page():
                out.append(Report.parse(self.version, raw))
        out.sort(key=lambda r: r.published, reverse=True)
        return out

    async def resolve_report(self, report: Report, resolved: bool = True) -> None:
        op = {"post": "post.report.resolve", "comment": "comment.report.resolve",
              "private_message": "pm.report.resolve"}[report.kind]
        await self.client.call(op, report_id=report.id, resolved=resolved)

    def modlog(self, community_id: int | None = None, limit: int = 30) -> ModelPager[ModlogEntry]:
        return self._pager("modlog", lambda r: ModlogEntry.parse(self.version, r), limit, community_id=community_id)

    # -- admin -----------------------------------------------------------------------
    async def registrations(self, unread_only: bool = True) -> list[RegistrationApplication]:
        pager = self.client.pager("admin.registrations", 50, unread_only=unread_only)
        return [RegistrationApplication.parse(self.version, r) for r in await pager.next_page()]

    async def approve(self, application_id: int, approve: bool, deny_reason: str | None = None) -> RegistrationApplication:
        data = await self.client.call("admin.approve", id=application_id, approve=approve,
                                      deny_reason=None if approve else (deny_reason or None))
        return RegistrationApplication.parse(self.version, data["registration_application"])

    async def purge(self, kind: str, target_id: int, reason: str | None = None) -> None:
        if kind not in ("person", "community", "post", "comment"):
            raise ValueError(kind)
        await self.client.call(f"admin.purge.{kind}", **{f"{kind}_id": target_id, "reason": reason or NO_REASON})
