"""Base screen with shared helpers and the actions every list/post screen offers."""
from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Any, Awaitable, TypeVar

from textual.binding import Binding
from textual.screen import Screen

from ... import urls
from ...client import AuthError, LutiError, UnsupportedOp
from ...models import Comment, Person, Post
from ..media import ImageScreen, markdown_images, open_external, post_media

if TYPE_CHECKING:
    from ...api import Lemmy
    from ..app import LutiApp

T = TypeVar("T")

# Keys for screens where a post or comment can be selected.
CONTENT_BINDINGS = [
    Binding("o", "open_link", "Open link"),
    Binding("p", "open_post_page", "Post page", show=False),
    Binding("c", "open_comment_page", "Comment page", show=False),
    Binding("m", "open_media", "Media", show=False),
    Binding("y", "copy_link", "Copy link", show=False),
    Binding("i", "view_image", "Image", show=False),
    Binding("asterisk", "toggle_star", "Star", key_display="*"),
]
CONTENT_HELP = [
    ("o", "open the source article (the post's link) in the browser"),
    ("p", "open the post's page on your instance"),
    ("c", "open the selected comment's page"),
    ("m", "open the image / video in the browser"),
    ("y", "copy the link that o opens"),
    ("i", "view the image full-screen"),
    ("*", "star / unstar the author (stargaze)"),
]


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

    # -- navigation ------------------------------------------------------------
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
        from ...models import Community

        if isinstance(obj, Post):
            self.open_post(obj.id)
        elif isinstance(obj, Comment):
            self.open_post(obj.post_id, comment_id=obj.id)
        elif isinstance(obj, Community):
            self.open_community(obj.handle.lstrip("!"))
        elif isinstance(obj, Person):
            self.open_person(username=obj.handle)

    # -- selection hooks (screens override) ------------------------------------
    def selected_post(self) -> Post | None:
        return None

    def selected_comment(self) -> Comment | None:
        return None

    def selected_person(self) -> Person | None:
        c = self.selected_comment()
        if c is not None and c.creator:
            return c.creator
        p = self.selected_post()
        return p.creator if p else None

    def after_star_change(self) -> None:
        """Re-render rows after the favorites changed."""
        from ..widgets import ItemList

        for lst in self.query(ItemList):
            lst.rerender()

    # -- browser / clipboard / image -------------------------------------------
    def _instance(self) -> str:
        return self.lemmy.client.instance

    def _link(self) -> str | None:
        post = self.selected_post()
        return urls.link_url(post) if post else None

    def action_open_link(self) -> None:
        post = self.selected_post()
        if post is None:
            return
        link = urls.link_url(post)
        if not link:
            self.notify("This post has no link; p opens its page", severity="warning")
            return
        open_external(self.app, link)

    def action_open_post_page(self) -> None:
        post = self.selected_post()
        if post is not None:
            open_external(self.app, urls.page_url(post, self._instance(), self.luti.setting_flag("open_origin")))

    def action_open_comment_page(self) -> None:
        comment = self.selected_comment()
        if comment is None:
            self.notify("No comment selected", severity="warning")
            return
        open_external(self.app, urls.page_url(comment, self._instance(), self.luti.setting_flag("open_origin")))

    def action_open_media(self) -> None:
        post = self.selected_post()
        url = urls.media_url(post) if post else None
        if not url:
            comment = self.selected_comment()
            imgs = markdown_images(comment.content if comment else (post.body if post else ""))
            url = imgs[0].url if imgs else None
        if not url:
            self.notify("No media here", severity="warning")
            return
        open_external(self.app, url)

    def action_copy_link(self) -> None:
        post = self.selected_post()
        url = self._link() or (urls.page_url(post, self._instance(), self.luti.setting_flag("open_origin")) if post else None)
        if not url:
            return
        self.app.copy_to_clipboard(url)
        self.notify(f"Copied {url}")

    def action_view_image(self) -> None:
        post = self.selected_post()
        media = post_media(post) if post else None
        if media is None or not media.url:
            comment = self.selected_comment()
            imgs = markdown_images(comment.content if comment else (post.body if post else ""))
            media = imgs[0] if imgs else None
        if media is None or not media.url:
            self.notify("No image here", severity="warning")
            return
        self.app.push_screen(ImageScreen(media, self.luti.image_cache, revealed=self.luti.nsfw_revealed(media.nsfw)))

    def action_toggle_star(self) -> None:
        person = self.selected_person()
        if person is None:
            self.notify("Select a post, comment or user first", severity="warning")
            return
        if self.need_login():
            return
        self.luti.toggle_star(person, self)
