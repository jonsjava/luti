"""The post feed: sort, time range, listing type and community filters."""
from __future__ import annotations

from rich.markup import escape
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.widgets import Footer, Header, Static

from ..api import LISTING_TYPES, POST_SORTS, TIME_RANGES, ModelPager
from ..models import Community, Post
from ..widgets import ItemList
from .base import LutiScreen
from .dialogs import PromptDialog


def _cycle(values: list[str], current: str, step: int = 1) -> str:
    i = values.index(current) if current in values else -1
    return values[(i + step) % len(values)]


class FeedScreen(LutiScreen):
    HELP_TITLE = "Feed"
    BINDINGS = [
        Binding("escape", "back", "Back", show=False),
        Binding("q", "quit_root", "Back/quit", show=False),
        Binding("enter", "open", "Open", show=False),
        Binding("u", "vote('up')", "Upvote"),
        Binding("d", "vote('down')", "Downvote"),
        Binding("s", "save", "Save"),
        Binding("r", "reply", "Reply"),
        Binding("o", "sort", "Sort"),
        Binding("t", "time", "Top time"),
        Binding("l", "listing", "Listing"),
        Binding("f", "community", "Community"),
        Binding("x", "clear_filter", "Clear filter", show=False),
        Binding("S", "toggle_saved", "Saved only", show=False),
        Binding("n", "new_post", "New post"),
        Binding("a", "author", "Author", show=False),
        Binding("c", "goto_community", "Go to community", show=False),
        Binding("b", "follow", "Follow/unfollow", show=False),
        Binding("R", "refresh", "Refresh"),
    ]
    EXTRA_HELP = [("enter", "open post"), ("x", "clear community filter"), ("S", "saved posts only"),
                  ("a", "author profile"), ("c", "open the post's community"),
                  ("b", "follow / unfollow the filtered community")]

    def __init__(self, community_name: str | None = None, sort: str | None = None, listing_type: str | None = None):
        super().__init__()
        self.community_name = community_name
        self.community: Community | None = None
        self.sort = sort or "active"
        self.time_range = "day"
        self.listing_type = listing_type
        self.saved_only = False
        self.pager: ModelPager[Post] | None = None
        self._loading = False

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("", id="filter-bar")
        yield ItemList(id="posts")
        yield Footer()

    def on_mount(self) -> None:
        if self.listing_type is None:
            self.listing_type = "local" if self.luti.lemmy and not self.luti.lemmy.client.token else "all"
            if self.luti.lemmy and self.luti.lemmy.me and self.luti.lemmy.me.follows and not self.community_name:
                self.listing_type = "subscribed"
        self.query_one(ItemList).focus()
        self.reload()

    def on_screen_resume(self) -> None:
        self.luti.refresh_title()

    # -- loading ---------------------------------------------------------------
    def _bar(self) -> None:
        parts = [f"[b]sort[/] {self.sort}"]
        if self.sort == "top":
            parts.append(f"[b]time[/] {self.time_range}")
        if self.community_name:
            label = self.community.handle if self.community else f"!{self.community_name}"
            sub = ""
            if self.community:
                sub = " [green]✓[/]" if self.community.is_subscribed else " [dim](not followed)[/]"
            parts.append(f"[b]community[/] [green]{escape(label)}[/]{sub}")
        else:
            parts.append(f"[b]listing[/] {self.listing_type}")
        if self.saved_only:
            parts.append("[magenta]saved only[/]")
        self.query_one("#filter-bar", Static).update("  ·  ".join(parts))
        self.sub_title = self.community.title if self.community else "feed"

    @work(exclusive=True, group="feed")
    async def reload(self) -> None:
        self._bar()
        lst = self.query_one(ItemList)
        await lst.clear()
        if self.community_name and (self.community is None or self.community.name != self.community_name.split("@")[0]):
            self.community = await self.guard(self.lemmy.community(name=self.community_name))
            self._bar()
        self.pager = self.lemmy.posts(
            sort=self.sort, time_range=self.time_range, listing_type=None if self.community_name else self.listing_type,
            community_name=self.community_name, saved_only=self.saved_only or None,
        )
        posts = await self.guard(self.pager.next_page())
        if posts is not None:
            await lst.set_items(posts)
            if not posts:
                self.notify("No posts here")

    @work(exclusive=True, group="feed-more")
    async def load_more(self) -> None:
        if self._loading or not self.pager or not self.pager.has_more:
            return
        self._loading = True
        try:
            posts = await self.guard(self.pager.next_page())
            if posts:
                lst = self.query_one(ItemList)
                have = {p.id for p in lst.objects}
                await lst.add_items([p for p in posts if p.id not in have])
        finally:
            self._loading = False

    @on(ItemList.NearEnd)
    def _near_end(self) -> None:
        self.load_more()

    @on(ItemList.Selected)
    def _selected(self, event: ItemList.Selected) -> None:
        self.action_open()

    def current(self) -> Post | None:
        return self.query_one(ItemList).current

    # -- actions ---------------------------------------------------------------
    def action_open(self) -> None:
        post = self.current()
        if post:
            self.open_post(post.id)

    @work(group="act")
    async def action_vote(self, direction: str) -> None:
        post = self.current()
        if not post or self.need_login():
            return
        vote = "clear" if post.my_vote == direction else direction
        updated = await self.guard(self.lemmy.vote_post(post.id, vote))
        if updated:
            self.query_one(ItemList).update_current(updated)

    @work(group="act")
    async def action_save(self) -> None:
        post = self.current()
        if not post or self.need_login():
            return
        updated = await self.guard(self.lemmy.save_post(post.id, not post.saved), "Saved" if not post.saved else "Unsaved")
        if updated:
            self.query_one(ItemList).update_current(updated)

    def action_reply(self) -> None:
        post = self.current()
        if not post or self.need_login():
            return
        from .compose import ComposeScreen

        self.app.push_screen(ComposeScreen.comment(post.id, None, context=post.title))

    def action_sort(self, step: int = 1) -> None:
        self.sort = _cycle(POST_SORTS, self.sort, step)
        self.reload()

    def action_time(self) -> None:
        if self.sort != "top":
            self.sort = "top"
        else:
            self.time_range = _cycle(TIME_RANGES, self.time_range)
        self.reload()

    def action_listing(self) -> None:
        types = list(LISTING_TYPES)
        if not self.lemmy.client.token:
            types = ["all", "local"]
        elif not self.lemmy.is_mod:
            types.remove("moderator_view")
        self.community_name = None
        self.community = None
        self.listing_type = _cycle(types, self.listing_type or "all")
        self.reload()

    def action_community(self) -> None:
        def done(name: str | None) -> None:
            if name:
                self.community_name = name.lstrip("!")
                self.community = None
                self.reload()

        self.app.push_screen(PromptDialog("Community (name or name@instance)", self.community_name or ""), done)

    def action_clear_filter(self) -> None:
        if self.community_name or self.saved_only:
            self.community_name = None
            self.community = None
            self.saved_only = False
            self.reload()

    def action_toggle_saved(self) -> None:
        if self.need_login():
            return
        self.saved_only = not self.saved_only
        self.reload()

    def action_new_post(self) -> None:
        if self.need_login():
            return
        from .compose import ComposeScreen

        def done(post: Post | None) -> None:
            if post:
                self.open_post(post.id)

        community = self.community_name or (self.current().community.handle.lstrip("!") if self.current() and self.current().community else "")
        self.app.push_screen(ComposeScreen.post(community), done)

    def action_author(self) -> None:
        post = self.current()
        if post and post.creator:
            self.open_person(username=post.creator.handle)

    def action_goto_community(self) -> None:
        post = self.current()
        if post and post.community:
            self.open_community(post.community.handle.lstrip("!"))

    @work(group="act")
    async def action_follow(self) -> None:
        if not self.community or self.need_login():
            self.notify("Filter to a community first (f)", severity="warning")
            return
        follow = not self.community.is_subscribed
        updated = await self.guard(self.lemmy.follow(self.community.id, follow),
                                   f"{'Followed' if follow else 'Unfollowed'} {self.community.handle}")
        if updated:
            self.community = updated
            self._bar()

    def action_quit_root(self) -> None:
        if len(self.app.screen_stack) > 2:
            self.app.pop_screen()
        else:
            self.app.exit()
