"""Community browser."""
from __future__ import annotations

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.widgets import Footer, Markdown, Static

from ...api import ModelPager
from ...models import Community
from ..widgets import ItemList, SafeHeader
from .base import LutiScreen
from .dialogs import PromptDialog

COMMUNITY_SORTS = ["hot", "new", "old"]


class CommunitiesScreen(LutiScreen):
    HELP_TITLE = "Communities"
    SUB_TITLE = "communities"
    BINDINGS = [
        Binding("enter", "open", "Open", show=False),
        Binding("b,plus", "follow", "Follow/unfollow"),
        Binding("l", "listing", "Listing"),
        Binding("S", "sort", "Sort"),
        Binding("f", "goto", "Go to…"),
        Binding("L", "modlog", "Modlog", show=False),
        Binding("R", "refresh", "Refresh"),
    ]
    EXTRA_HELP = [("enter", "open the community feed"), ("L", "this community's modlog")]

    def __init__(self):
        super().__init__()
        self.listing = "all"
        self.sort = "hot"
        self.pager: ModelPager[Community] | None = None

    def compose(self) -> ComposeResult:
        yield SafeHeader()
        yield Static("", id="filter-bar")
        yield ItemList(id="communities")
        with VerticalScroll(id="detail"):
            yield Markdown("", id="detail-md")
        yield Footer()

    def on_mount(self) -> None:
        if self.luti.lemmy and self.luti.lemmy.client.token and self.luti.lemmy.me and self.luti.lemmy.me.follows:
            self.listing = "subscribed"
        self.query_one(ItemList).focus()
        self.action_refresh()

    @work(exclusive=True, group="communities")
    async def action_refresh(self) -> None:
        self.query_one("#filter-bar", Static).update(f"[b]listing[/] {self.listing}  ·  [b]sort[/] {self.sort}")
        self.pager = self.lemmy.communities(listing_type=self.listing, sort=self.sort)
        items = await self.guard(self.pager.next_page())
        if items is not None:
            await self.query_one(ItemList).set_items(items)

    @on(ItemList.NearEnd)
    @work(exclusive=True, group="communities-more")
    async def _more(self) -> None:
        if self.pager and self.pager.has_more:
            items = await self.guard(self.pager.next_page())
            if items:
                lst = self.query_one(ItemList)
                have = {c.id for c in lst.objects}
                await lst.add_items([c for c in items if c.id not in have])

    def current(self) -> Community | None:
        return self.query_one(ItemList).current

    @on(ItemList.Highlighted)
    async def _highlighted(self, event: ItemList.Highlighted) -> None:
        c = self.current()
        if c:
            await self.query_one("#detail-md", Markdown).update(f"## {c.title}\n\n`{c.handle}`\n\n{c.description or ''}")

    @on(ItemList.Selected)
    def _selected(self, event: ItemList.Selected) -> None:
        self.action_open()

    def action_open(self) -> None:
        c = self.current()
        if c:
            self.open_community(c.handle.lstrip("!"))

    @work(group="act")
    async def action_follow(self) -> None:
        c = self.current()
        if c is None or self.need_login():
            return
        follow = not c.is_subscribed
        updated = await self.guard(self.lemmy.follow(c.id, follow), f"{'Followed' if follow else 'Unfollowed'} {c.handle}")
        if updated:
            self.query_one(ItemList).update_current(updated)

    def action_listing(self) -> None:
        options = ["all", "local", "subscribed"] if self.lemmy.client.token else ["all", "local"]
        self.listing = options[(options.index(self.listing) + 1) % len(options)] if self.listing in options else "all"
        self.action_refresh()

    def action_sort(self) -> None:
        self.sort = COMMUNITY_SORTS[(COMMUNITY_SORTS.index(self.sort) + 1) % len(COMMUNITY_SORTS)]
        self.action_refresh()

    def action_goto(self) -> None:
        def done(name: str | None) -> None:
            if name:
                self.open_community(name.lstrip("!"))

        self.app.push_screen(PromptDialog("Community (name or name@instance)"), done)

    def action_modlog(self) -> None:
        c = self.current()
        if c:
            from .mod import ModlogScreen

            self.app.push_screen(ModlogScreen(community=c))
