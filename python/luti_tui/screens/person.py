"""A user's profile with their posts and comments."""
from __future__ import annotations

from rich.markup import escape
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, Header, Static

from ..models import Person
from ..widgets import ItemList, ago
from .base import LutiScreen
from .dialogs import BanDialog


class PersonScreen(LutiScreen):
    HELP_TITLE = "Profile"
    BINDINGS = [
        Binding("enter", "open", "Open", show=False),
        Binding("m", "message", "Message"),
        Binding("B", "ban", "Site ban", show=False),
        Binding("R", "refresh", "Refresh"),
    ]
    EXTRA_HELP = [("enter", "open the post or comment"), ("B", "ban / unban from the site (admins)")]

    def __init__(self, username: str | None = None, person_id: int | None = None):
        super().__init__()
        self.username = username
        self.person_id = person_id
        self.person: Person | None = None

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("", id="person-head")
        yield ItemList(id="person-items")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self.username or "profile"
        self.query_one(ItemList).focus()
        self.action_refresh()

    @work(exclusive=True, group="person")
    async def action_refresh(self) -> None:
        res = await self.guard(self.lemmy.person(username=self.username, person_id=self.person_id))
        if res is None:
            return
        self.person, items = res
        p = self.person
        flags = [f for f, on_ in (("[b red]admin[/]", p.admin), ("[red]banned[/]", p.banned),
                                  ("[dim]bot[/]", p.bot), ("[red]deleted[/]", p.deleted)) if on_]
        stats = []
        if p.post_count is not None:
            stats.append(f"{p.post_count} posts")
        if p.comment_count is not None:
            stats.append(f"{p.comment_count} comments")
        lines = [f"[b cyan]{escape(p.handle)}[/] {escape(p.display_name or '')} {' '.join(flags)}",
                 f"[dim]joined {ago(p.published)} ago · {' · '.join(stats)}[/]"]
        if p.bio:
            lines.append(escape(p.bio.strip()[:400]))
        self.query_one("#person-head", Static).update("\n".join(lines))
        self.sub_title = p.handle
        await self.query_one(ItemList).set_items(items)

    @on(ItemList.Selected)
    def _selected(self, event: ItemList.Selected) -> None:
        self.action_open()

    def action_open(self) -> None:
        obj = self.query_one(ItemList).current
        if obj is not None:
            self.open_object(obj)

    def action_message(self) -> None:
        if self.person is None or self.need_login():
            return
        from .compose import ComposeScreen

        self.app.push_screen(ComposeScreen.message(self.person.handle, self.person.id))

    @work(group="act")
    async def action_ban(self) -> None:
        if self.person is None or self.need_login():
            return
        if not self.lemmy.is_admin:
            self.notify("Only admins can ban from the site", severity="warning")
            return
        unban = self.person.banned
        opts = await self.app.push_screen_wait(BanDialog(f"{'Unban' if unban else 'Ban'} {self.person.handle} (site-wide)", unban=unban))
        if opts is None:
            return
        if await self.attempt(self.lemmy.ban_site(self.person.id, not unban, opts.reason, opts.remove_data, opts.days),
                              f"{'Unbanned' if unban else 'Banned'} {self.person.handle}"):
            self.action_refresh()
