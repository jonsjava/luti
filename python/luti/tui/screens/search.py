"""Search posts, comments, communities and users."""
from __future__ import annotations

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import Footer, Input, Select

from ...api import SEARCH_TYPES
from ...models import Comment, Person, Post
from ..widgets import ItemList, SafeHeader
from .base import CONTENT_BINDINGS, CONTENT_HELP, LutiScreen


class SearchScreen(LutiScreen):
    HELP_TITLE = "Search"
    SUB_TITLE = "search"
    BINDINGS = [
        Binding("escape", "back", "Back"),
        Binding("slash", "focus_query", "Search box", show=False),
        Binding("enter", "open", "Open", show=False),
        *CONTENT_BINDINGS,
    ]
    EXTRA_HELP = [("enter", "in the box: search; on a result: open it"), ("/", "back to the search box"),
                  ("tab", "move between the box, type and results"), *CONTENT_HELP]

    def __init__(self, query: str = ""):
        super().__init__()
        self.initial = query

    def compose(self) -> ComposeResult:
        yield SafeHeader()
        with Horizontal(id="search-bar"):
            yield Input(self.initial, placeholder="Search…", id="query")
            yield Select([(t, t) for t in SEARCH_TYPES], value="all", allow_blank=False, id="search-type")
            yield Select([(t, t) for t in ("all", "local")], value="all", allow_blank=False, id="search-listing")
        yield ItemList(id="results")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#query", Input).focus()
        if self.initial:
            self.run_search()

    def action_focus_query(self) -> None:
        self.query_one("#query", Input).focus()

    @on(Input.Submitted, "#query")
    def _submit(self) -> None:
        self.run_search()

    @on(Select.Changed)
    def _type(self) -> None:
        if self.query_one("#query", Input).value.strip():
            self.run_search()

    @work(exclusive=True, group="search")
    async def run_search(self) -> None:
        q = self.query_one("#query", Input).value.strip()
        if not q:
            return
        t = self.query_one("#search-type", Select).value
        listing = self.query_one("#search-listing", Select).value
        results = await self.guard(self.lemmy.search(q, type_=str(t), listing_type=str(listing)))
        if results is None:
            return
        lst = self.query_one(ItemList)
        await lst.set_items(results)
        if results:
            lst.focus()
        else:
            self.notify("No results")

    @on(ItemList.Selected)
    def _selected(self, event: ItemList.Selected) -> None:
        self.action_open()

    def selected_post(self) -> Post | None:
        obj = self.query_one(ItemList).current
        if isinstance(obj, Post):
            return obj
        if isinstance(obj, Comment):
            return Post(id=obj.post_id, title=obj.post_title)
        return None

    def selected_comment(self) -> Comment | None:
        obj = self.query_one(ItemList).current
        return obj if isinstance(obj, Comment) else None

    def selected_person(self) -> Person | None:
        obj = self.query_one(ItemList).current
        return obj if isinstance(obj, Person) else super().selected_person()

    def action_open(self) -> None:
        obj = self.query_one(ItemList).current
        if obj is not None:
            self.open_object(obj)
