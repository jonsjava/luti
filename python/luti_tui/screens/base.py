"""Base screen with shared helpers."""
from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Any, Awaitable, TypeVar

from textual.binding import Binding
from textual.screen import Screen

from ..client import AuthError, LutiError, UnsupportedOp

if TYPE_CHECKING:
    from ..api import Lemmy
    from ..app import LutiApp

T = TypeVar("T")


class LutiScreen(Screen):
    HELP_TITLE = ""
    EXTRA_HELP: list[tuple[str, str]] = []

    BINDINGS = [
        Binding("escape,q", "back", "Back"),
    ]

    @property
    def luti(self) -> "LutiApp":
        return self.app  # type: ignore[return-value]

    @property
    def lemmy(self) -> "Lemmy":
        assert self.luti.lemmy is not None, "not logged in"
        return self.luti.lemmy

    @property
    def alive(self) -> bool:
        """Still on the screen stack (popped screens can outlive their workers briefly)."""
        return self.is_attached and self in self.app.screen_stack

    def action_back(self) -> None:
        if len(self.app.screen_stack) > 2:
            self.app.pop_screen()

    async def guard(self, aw: Awaitable[T], ok: str | None = None) -> T | None:
        """Await `aw`, show luti errors as notifications instead of crashing.

        If the screen was closed while waiting, the calling worker is cancelled
        so it doesn't touch widgets that no longer exist.
        """
        error: LutiError | None = None
        result: T | None = None
        try:
            result = await aw
        except LutiError as e:
            error = e
        if not self.alive:
            raise asyncio.CancelledError
        if isinstance(error, UnsupportedOp):
            self.notify(str(error), severity="warning")
        elif isinstance(error, AuthError):
            self.notify(f"{error.error}: {error.message or 'not logged in'}", title="Authentication", severity="error")
        elif error is not None:
            self.notify(str(error), severity="error", timeout=8)
        elif ok:
            self.notify(ok)
        return None if error else result

    async def attempt(self, aw: Awaitable[Any], ok: str | None = None) -> bool:
        """Like guard(), for calls without a useful result: True on success."""
        sentinel = object()

        async def wrapped():
            await aw
            return sentinel

        return (await self.guard(wrapped(), ok)) is sentinel

    def need_login(self) -> bool:
        if self.luti.lemmy is None or not self.luti.lemmy.client.token:
            self.notify("Log in first (P)", severity="warning")
            return True
        return False

    def open_post(self, post_id: int, comment_id: int | None = None) -> None:
        from .post import PostScreen

        self.app.push_screen(PostScreen(post_id, focus_comment=comment_id))

    def open_person(self, username: str | None = None, person_id: int | None = None) -> None:
        from .person import PersonScreen

        self.app.push_screen(PersonScreen(username=username, person_id=person_id))

    def open_community(self, name: str) -> None:
        from .feed import FeedScreen

        self.app.push_screen(FeedScreen(community_name=name))

    def open_object(self, obj: Any) -> None:
        from ..models import Comment, Community, Person, Post

        if isinstance(obj, Post):
            self.open_post(obj.id)
        elif isinstance(obj, Comment):
            self.open_post(obj.post_id, comment_id=obj.id)
        elif isinstance(obj, Community):
            self.open_community(obj.handle.lstrip("!"))
        elif isinstance(obj, Person):
            self.open_person(username=obj.handle)
