"""Admin: registration applications, site bans and purges."""
from __future__ import annotations

from rich.markup import escape
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Button, Checkbox, Footer, Header, Input, Label, Select, Static, TabbedContent, TabPane

from ..models import RegistrationApplication
from ..widgets import ItemList
from .base import LutiScreen
from .dialogs import ConfirmDialog, PromptDialog

BAN_ACTIONS = ("mod_ban", "admin_ban", "mod_ban_from_community")


class AdminScreen(LutiScreen):
    HELP_TITLE = "Admin"
    BINDINGS = [
        Binding("y", "approve", "Approve"),
        Binding("n", "deny", "Deny"),
        Binding("a", "toggle_pending", "Pending/all"),
        Binding("R", "refresh", "Refresh"),
        Binding("1", "tab('registrations')", "Registrations", show=False),
        Binding("2", "tab('bans')", "Bans", show=False),
        Binding("3", "tab('purge')", "Purge", show=False),
    ]
    EXTRA_HELP = [("1 / 2 / 3", "registrations / bans / purge tab"),
                  ("y / n", "approve / deny the highlighted application")]

    def __init__(self):
        super().__init__()
        self.pending_only = True

    def compose(self) -> ComposeResult:
        yield Header()
        with TabbedContent(initial="registrations"):
            with TabPane("Registrations", id="registrations"):
                yield Static("", id="reg-bar")
                yield ItemList(id="applications")
            with TabPane("Bans", id="bans"):
                with Vertical(classes="form"):
                    yield Label("Ban or unban a user site-wide")
                    yield Input(placeholder="Username (or user@instance)", id="ban-user")
                    yield Input(placeholder="Reason", id="ban-reason")
                    yield Input(placeholder="Days (empty = permanent)", id="ban-days", type="number")
                    yield Checkbox("Remove (or restore) their content", id="ban-remove")
                    with Horizontal(classes="buttons"):
                        yield Button("Ban", id="ban-btn", variant="error")
                        yield Button("Unban", id="unban-btn", variant="warning")
                yield Label("[b]Recent bans (modlog)[/]", id="bans-title")
                yield ItemList(id="recent-bans")
            with TabPane("Purge", id="purge"):
                with Vertical(classes="form"):
                    yield Label("[b red]Purging deletes permanently. It cannot be undone.[/]")
                    yield Select([("Person (username)", "person"), ("Community (name)", "community"),
                                  ("Post (id)", "post"), ("Comment (id)", "comment")],
                                 value="post", allow_blank=False, id="purge-kind")
                    yield Input(placeholder="Username, community name or id", id="purge-target")
                    yield Input(placeholder="Reason", id="purge-reason")
                    yield Button("Purge…", id="purge-btn", variant="error")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "admin"
        if not self.lemmy.is_admin:
            self.notify("You are not an admin on this instance", severity="warning")
        self.query_one("#applications", ItemList).focus()
        self.action_refresh()

    def action_tab(self, tab: str) -> None:
        # Drop focus first: if it stays inside the pane being hidden, Textual
        # moves it to a sibling there and TabbedContent switches straight back.
        self.set_focus(None)
        self.query_one(TabbedContent).active = tab
        first = {"registrations": "#applications", "bans": "#ban-user", "purge": "#purge-kind"}[tab]
        self.call_after_refresh(self.query_one(first).focus)

    @on(TabbedContent.TabActivated)
    def _tab(self, event: TabbedContent.TabActivated) -> None:
        if event.pane.id == "bans":
            self.load_bans()

    @work(exclusive=True, group="apps")
    async def action_refresh(self) -> None:
        self.query_one("#reg-bar", Static).update(
            f"[b]{'pending' if self.pending_only else 'all'}[/] applications  [dim](a to toggle · y approve · n deny)[/]")
        apps = await self.guard(self.lemmy.registrations(unread_only=self.pending_only))
        if apps is not None:
            await self.query_one("#applications", ItemList).set_items(apps)
            if not apps:
                self.notify("No applications")
        self.luti.refresh_unread()

    @work(exclusive=True, group="bans")
    async def load_bans(self) -> None:
        entries = []
        pager = self.lemmy.modlog(limit=50)
        for _ in range(3):
            page = await self.guard(pager.next_page())
            if not page:
                break
            entries += [e for e in page if e.action in BAN_ACTIONS]
            if not pager.has_more:
                break
        await self.query_one("#recent-bans", ItemList).set_items(entries)

    def action_toggle_pending(self) -> None:
        self.pending_only = not self.pending_only
        self.action_refresh()

    def current_app(self) -> RegistrationApplication | None:
        return self.query_one("#applications", ItemList).current

    @work(group="act")
    async def action_approve(self) -> None:
        a = self.current_app()
        if a is None:
            return
        if await self.attempt(self.lemmy.approve(a.id, True), f"Approved {a.creator.name if a.creator else a.id}"):
            self.action_refresh()

    @work(group="act")
    async def action_deny(self) -> None:
        a = self.current_app()
        if a is None:
            return
        reason = await self.app.push_screen_wait(PromptDialog(f"Deny {a.creator.name if a.creator else a.id}? Reason:"))
        if reason is None:
            return
        if await self.attempt(self.lemmy.approve(a.id, False, reason), "Application denied"):
            self.action_refresh()

    @on(Button.Pressed, "#ban-btn")
    def _ban(self) -> None:
        self.do_ban(True)

    @on(Button.Pressed, "#unban-btn")
    def _unban(self) -> None:
        self.do_ban(False)

    @work(group="act")
    async def do_ban(self, ban: bool) -> None:
        user = self.query_one("#ban-user", Input).value.strip().lstrip("@")
        if not user:
            self.notify("Enter a username", severity="warning")
            return
        days_raw = self.query_one("#ban-days", Input).value.strip()
        try:
            days = float(days_raw) if days_raw else None
        except ValueError:
            self.notify("Days must be a number", severity="warning")
            return
        person = await self.guard(self.lemmy.find_person(user))
        if person is None:
            return
        ok = await self.attempt(self.lemmy.ban_site(person.id, ban, self.query_one("#ban-reason", Input).value.strip(),
                                                    self.query_one("#ban-remove", Checkbox).value, days),
                                f"{'Banned' if ban else 'Unbanned'} {person.handle}")
        if ok:
            self.load_bans()

    @on(Button.Pressed, "#purge-btn")
    @work(group="act")
    async def do_purge(self) -> None:
        kind = str(self.query_one("#purge-kind", Select).value)
        target = self.query_one("#purge-target", Input).value.strip().lstrip("!@")
        reason = self.query_one("#purge-reason", Input).value.strip()
        if not target:
            self.notify("Enter what to purge", severity="warning")
            return
        if kind in ("post", "comment"):
            if not target.isdigit():
                self.notify(f"A {kind} is purged by its numeric id", severity="warning")
                return
            target_id, label = int(target), f"{kind} #{target}"
        elif kind == "person":
            person = await self.guard(self.lemmy.find_person(target))
            if person is None:
                return
            target_id, label = person.id, f"user {person.handle}"
        else:
            community = await self.guard(self.lemmy.community(name=target))
            if community is None:
                return
            target_id, label = community.id, f"community {community.handle}"
        sure = await self.app.push_screen_wait(
            ConfirmDialog(f"Purge {escape(label)}? This permanently deletes it and everything in it.", "Purge", danger=True))
        if not sure:
            self.notify("Purge cancelled")
            return
        if await self.attempt(self.lemmy.purge(kind, target_id, reason), f"Purged {label}"):
            self.query_one("#purge-target", Input).value = ""
