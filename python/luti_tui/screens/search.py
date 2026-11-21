"""Search posts, comments, communities and users."""
from __future__ import annotations

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import Footer, Header, Input, Select

from ..api import SEARCH_TYPES
from ..widgets import ItemList
from .base import LutiScreen


class SearchScreen(LutiScreen):
    HELP_TITLE = "Search"
    BINDINGS = [
        Binding("escape", "back", "Back"),
        Binding("slash", "focus_query", "Search box", show=False),
        Binding("enter", "open", "Open", show=False),
    ]
    EXTRA_HELP = [("enter", "in the box: search; on a result: open it"), ("/", "back to the search box"),
                  ("tab", "move between the box, type and results")]

    def __init__(self, query: str = ""):
        super().__init__()
        self.initial = query

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="search-bar"):
            yield Input(self.initial, placeholder="Search…", id="query")
            yield Select([(t, t) for t in SEARCH_TYPES], value="all", allow_blank=False, id="search-type")
            yield Select([(t, t) for t in ("all", "local")], value="all", allow_blank=False, id="search-listing")
        yield ItemList(id="results")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "search"
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

    def action_open(self) -> None:
        obj = self.query_one(ItemList).current
        if obj is not None:
            self.open_object(obj)
