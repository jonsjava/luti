"""Stargaze: new posts from starred users, oldest first."""
from __future__ import annotations

from rich.markup import escape
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Footer, Label, Static

from ...models import Person, Post
from ..widgets import ItemList, Row, SafeHeader, render_post
from .base import CONTENT_BINDINGS, CONTENT_HELP, LutiScreen


class StargazeScreen(LutiScreen):
    HELP_TITLE = "Stargaze"
    SUB_TITLE = "stargaze"
    BINDINGS = [
        Binding("enter", "open", "Open", show=False),
        Binding("n", "next_unread", "Next unread"),
        Binding("x", "mark_all", "Mark all seen"),
        Binding("a", "toggle_seen", "Show seen"),
        Binding("u", "vote('up')", "Upvote", show=False),
        Binding("d", "vote('down')", "Downvote", show=False),
        Binding("tab", "switch_pane", "Favorites", show=False),
        Binding("R", "refresh", "Refresh"),
        *CONTENT_BINDINGS,
    ]
    EXTRA_HELP = [
        ("enter", "open the post (marks it and that user's older posts seen)"),
        ("n", "open the next unread post"), ("x", "mark everything seen"),
        ("a", "also show posts already seen"), ("tab", "switch to the favorites list"),
        ("enter (favorites)", "show only that user"), ("* (favorites)", "unstar that user"),
        *CONTENT_HELP,
    ]

    def __init__(self) -> None:
        super().__init__()
        self.show_seen = False
        self.only: str | None = None
        self.counts: dict[str, int] = {}

    def compose(self) -> ComposeResult:
        yield SafeHeader()
        yield Static("", id="filter-bar")
        with Horizontal(id="stargaze"):
            yield ItemList(id="stargaze-posts")
            with Vertical(id="favorites-pane"):
                yield Label("[b]★ Favorites[/]")
                yield ItemList(id="favorites")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#stargaze-posts", ItemList).focus()
        self.action_refresh()

    @property
    def stars(self):
        return self.luti.stars

    def _bar(self, n: int) -> None:
        who = self.only or "all favorites"
        mode = "unread + seen" if self.show_seen else "unread"
        self.query_one("#filter-bar", Static).update(
            f"[b]{n}[/] {mode} posts from [b]{escape(who)}[/]  [dim](n next · x mark all seen · a show seen · tab favorites)[/]")

    @work(exclusive=True, group="stargaze")
    async def action_refresh(self) -> None:
        if self.need_login() or self.stars is None:
            return
        users = self.stars.list()
        if not users:
            await self.query_one("#stargaze-posts", ItemList).set_items([])
            await self.query_one("#favorites", ItemList).set_items([])
            self.query_one("#filter-bar", Static).update(
                "No favorites yet. Press [b]*[/] on a post, comment or profile to star its author.")
            return
        if self.show_seen:
            posts = await self.guard(self.stars.recent(self.lemmy, user=self.only)) or []
        else:
            posts = await self.guard(self.stars.stargaze(self.lemmy, user=self.only)) or []
        unread = await self.guard(self.stars.stargaze(self.lemmy)) if self.show_seen or self.only else posts
        self.counts = {u: 0 for u in users}
        for p in unread or []:
            author = self.stars.author_of(p)
            if author in self.counts:
                self.counts[author] += 1
        for w in self.stars.warnings:
            self.notify(w, severity="warning")
        await self._fill_posts(posts)
        await self._fill_favorites()
        self.luti.stargaze_unread = sum(self.counts.values())
        self.luti.refresh_title()

    async def _fill_posts(self, posts: list[Post]) -> None:
        lst = self.query_one("#stargaze-posts", ItemList)
        await lst.clear()
        rows = []
        for p in posts:
            seen = self.stars.is_seen(p)
            rows.append(Row(p, ("[dim]seen[/] " if seen else "[b yellow]●[/] ") + render_post(p)))
        await lst.extend(rows)
        if rows:
            lst.index = 0
        self._bar(len(posts))

    async def _fill_favorites(self) -> None:
        fav = self.query_one("#favorites", ItemList)
        keep = fav.index or 0
        await fav.clear()
        rows = [Row(u, f"{'[b]' if self.counts.get(u) else '[dim]'}{escape(u)}[/] "
                       f"{'[b yellow]' + str(self.counts[u]) + '[/]' if self.counts.get(u) else ''}"
                       f"{'  [reverse]filter[/]' if u == self.only else ''}")
                for u in self.stars.list()]
        await fav.extend(rows)
        if rows:
            fav.index = min(keep, len(rows) - 1)

    # -- selection -----------------------------------------------------------------
    def selected_post(self) -> Post | None:
        obj = self.query_one("#stargaze-posts", ItemList).current
        return obj if isinstance(obj, Post) else None

    def selected_person(self) -> Person | None:
        post = self.selected_post()
        return post.creator if post else None

    def _open(self, post: Post) -> None:
        author = self.stars.author_of(post)
        if author:
            self.stars.mark_seen(author, post.id)
        self.open_post(post.id)

    def on_screen_resume(self) -> None:
        if self.is_mounted:
            self.action_refresh()

    @on(ItemList.Selected, "#stargaze-posts")
    def _selected(self) -> None:
        self.action_open()

    @on(ItemList.Selected, "#favorites")
    def _filter(self, event: ItemList.Selected) -> None:
        user = getattr(event.item, "obj", None)
        self.only = None if user == self.only else user
        self.action_refresh()

    # -- actions -------------------------------------------------------------------
    def action_open(self) -> None:
        post = self.selected_post()
        if post:
            self._open(post)

    def action_next_unread(self) -> None:
        lst = self.query_one("#stargaze-posts", ItemList)
        for obj in lst.objects:
            if isinstance(obj, Post) and not self.stars.is_seen(obj):
                self._open(obj)
                return
        self.notify("No unread posts. ✨")

    def action_mark_all(self) -> None:
        if self.stars is None:
            return
        posts = [o for o in self.query_one("#stargaze-posts", ItemList).objects if isinstance(o, Post)]
        self.stars.mark_all_seen(posts)
        self.notify("All marked seen")
        self.action_refresh()

    def action_toggle_seen(self) -> None:
        self.show_seen = not self.show_seen
        self.action_refresh()

    def action_switch_pane(self) -> None:
        posts, fav = self.query_one("#stargaze-posts", ItemList), self.query_one("#favorites", ItemList)
        (fav if posts.has_focus else posts).focus()

    def action_toggle_star(self) -> None:
        fav = self.query_one("#favorites", ItemList)
        if fav.has_focus and isinstance(fav.current, str) and self.stars:
            self.stars.remove(fav.current)
            from ..widgets import STARRED

            STARRED.discard(fav.current)
            self.notify(f"Unstarred {fav.current}")
            if self.only == fav.current:
                self.only = None
            self.action_refresh()
            return
        super().action_toggle_star()

    def after_star_change(self) -> None:
        self.action_refresh()

    @work(group="act")
    async def action_vote(self, direction: str) -> None:
        post = self.selected_post()
        if post is None:
            return
        vote = "clear" if post.my_vote == direction else direction
        updated = await self.guard(self.lemmy.vote_post(post.id, vote))
        if updated:
            lst = self.query_one("#stargaze-posts", ItemList)
            child = lst.highlighted_child
            if isinstance(child, Row):
                child.obj = updated
                prefix = "[dim]seen[/] " if self.stars.is_seen(updated) else "[b yellow]●[/] "
                child.query(Label).last().update(prefix + render_post(updated))
