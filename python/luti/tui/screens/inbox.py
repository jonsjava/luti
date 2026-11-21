"""Inbox: replies, mentions and messages (v3) or notifications (v4)."""
from __future__ import annotations

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.widgets import Footer, Markdown, Static

from ...models import Comment, Notification, Person, Post
from ..widgets import ItemList, SafeHeader, ago
from .base import CONTENT_BINDINGS, CONTENT_HELP, LutiScreen


class InboxScreen(LutiScreen):
    HELP_TITLE = "Inbox"
    SUB_TITLE = "inbox"
    BINDINGS = [
        Binding("enter", "open", "Open", show=False),
        Binding("r", "reply", "Reply"),
        Binding("a", "toggle_unread", "Unread/all"),
        Binding("e", "mark_read", "Mark read"),
        Binding("ctrl+a", "mark_all", "Mark all read"),
        Binding("u", "vote('up')", "Upvote", show=False),
        Binding("d", "vote('down')", "Downvote", show=False),
        Binding("R", "refresh", "Refresh"),
        *CONTENT_BINDINGS,
    ]
    EXTRA_HELP = [("enter", "open the post (comments) or show the message"),
                  ("e", "mark one item read (Lemmy 1.0 only)"), ("ctrl+a", "mark everything read"), *CONTENT_HELP]

    def __init__(self):
        super().__init__()
        self.unread_only = False

    def compose(self) -> ComposeResult:
        yield SafeHeader()
        yield Static("", id="filter-bar")
        yield ItemList(id="inbox")
        with VerticalScroll(id="detail"):
            yield Markdown("", id="detail-md")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one(ItemList).focus()
        self.action_refresh()

    @work(exclusive=True, group="inbox")
    async def action_refresh(self) -> None:
        if self.need_login():
            return
        kind = "notifications" if self.lemmy.is_v4 else "replies, mentions and messages"
        self.query_one("#filter-bar", Static).update(
            f"[b]{'unread' if self.unread_only else 'all'}[/] {kind}  [dim](a to toggle)[/]")
        items = await self.guard(self.lemmy.inbox(unread_only=self.unread_only))
        if items is not None:
            await self.query_one(ItemList).set_items(items)
            if not items:
                await self.query_one("#detail-md", Markdown).update("_Nothing here._")

    def current(self) -> Notification | None:
        return self.query_one(ItemList).current

    def selected_comment(self) -> Comment | None:
        n = self.current()
        return n.comment if n else None

    def selected_post(self) -> Post | None:
        c = self.selected_comment()
        return Post(id=c.post_id, title=c.post_title) if c else None

    def selected_person(self) -> Person | None:
        n = self.current()
        return n.creator if n else None

    @on(ItemList.Highlighted)
    async def _highlighted(self, event: ItemList.Highlighted) -> None:
        n = self.current()
        if n is None:
            return
        who = n.creator.handle if n.creator else "?"
        title = f"\n\non **{n.comment.post_title}**" if n.comment and n.comment.post_title else ""
        await self.query_one("#detail-md", Markdown).update(f"**{who}** · {n.kind} · {ago(n.published)}{title}\n\n---\n\n{n.text}")

    @on(ItemList.Selected)
    def _selected(self, event: ItemList.Selected) -> None:
        self.action_open()

    def action_open(self) -> None:
        n = self.current()
        if n is None:
            return
        self._auto_read(n)
        if n.comment:
            self.open_post(n.comment.post_id, comment_id=n.comment.id)
        elif n.message:
            self.action_reply()

    @work(group="act")
    async def _auto_read(self, n: Notification) -> None:
        if self.lemmy.is_v4 and not n.read:
            if await self.attempt(self.lemmy.mark_read(n)):
                n.read = True
                self.query_one(ItemList).update_current(n)
                self.luti.refresh_unread()

    def action_reply(self) -> None:
        n = self.current()
        if n is None:
            return
        from .compose import ComposeScreen

        if n.comment:
            self.app.push_screen(ComposeScreen.comment(n.comment.post_id, n.comment.id, context=n.comment.content))
        elif n.message and n.creator:
            self.app.push_screen(ComposeScreen.message(n.creator.handle, n.creator.id, context=n.message.content))
        else:
            self.notify("Nothing to reply to", severity="warning")

    @work(group="act")
    async def action_mark_read(self) -> None:
        n = self.current()
        if n is None:
            return
        if not self.lemmy.is_v4:
            self.notify("Lemmy 0.19 can only mark everything read (ctrl+a)", severity="warning")
            return
        if await self.attempt(self.lemmy.mark_read(n)):
            n.read = True
            self.query_one(ItemList).update_current(n)
            self.luti.refresh_unread()

    @work(group="act")
    async def action_mark_all(self) -> None:
        if await self.attempt(self.lemmy.mark_all_read(), "All marked read"):
            self.luti.refresh_unread()
            self.action_refresh()

    def action_toggle_unread(self) -> None:
        self.unread_only = not self.unread_only
        self.action_refresh()

    @work(group="act")
    async def action_vote(self, direction: str) -> None:
        n = self.current()
        if n is None or n.comment is None:
            return
        vote = "clear" if n.comment.my_vote == direction else direction
        updated = await self.guard(self.lemmy.vote_comment(n.comment.id, vote))
        if updated:
            n.comment = updated
            self.query_one(ItemList).update_current(n)
