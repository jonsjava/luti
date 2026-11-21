"""Mod queue (reports) and modlog."""
from __future__ import annotations

from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import VerticalScroll
from textual.widgets import Footer, Header, Markdown, Static

from ..api import ModelPager
from ..models import Community, ModlogEntry, Report
from ..widgets import ItemList, ago
from .base import LutiScreen
from .dialogs import BanDialog, PromptDialog


class ModQueueScreen(LutiScreen):
    HELP_TITLE = "Mod queue"
    BINDINGS = [
        Binding("v", "resolve", "Resolve/reopen"),
        Binding("x", "remove", "Remove + resolve"),
        Binding("b", "ban", "Ban (community)"),
        Binding("B", "site_ban", "Site ban", show=False),
        Binding("enter", "open", "Open", show=False),
        Binding("a", "toggle_all", "Open/all"),
        Binding("R", "refresh", "Refresh"),
    ]
    EXTRA_HELP = [("enter", "open the reported post or comment"),
                  ("x", "remove (or restore) the content and resolve the report"),
                  ("b", "ban the author from the community (site ban for messages)"),
                  ("B", "ban the author site-wide (admins)")]

    def __init__(self):
        super().__init__()
        self.unresolved_only = True

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("", id="filter-bar")
        yield ItemList(id="reports")
        with VerticalScroll(id="detail"):
            yield Markdown("", id="detail-md")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "mod queue"
        self.query_one(ItemList).focus()
        self.action_refresh()

    @work(exclusive=True, group="reports")
    async def action_refresh(self, keep: tuple[str, int] | None = None) -> None:
        if self.need_login():
            return
        self.query_one("#filter-bar", Static).update(
            f"[b]{'open' if self.unresolved_only else 'all'}[/] reports  [dim](a to toggle)[/]")
        reports = await self.guard(self.lemmy.reports(unresolved_only=self.unresolved_only))
        if reports is None:
            return
        lst = self.query_one(ItemList)
        await lst.set_items(reports)
        if keep:
            for i, r in enumerate(reports):
                if (r.kind, r.id) == keep:
                    lst.index = i
        if not reports:
            await self.query_one("#detail-md", Markdown).update("_No reports. Nice._")
        self.luti.refresh_unread()

    def current(self) -> Report | None:
        return self.query_one(ItemList).current

    @on(ItemList.Highlighted)
    async def _highlighted(self, event: ItemList.Highlighted) -> None:
        r = self.current()
        if r is None:
            return
        who = r.target_creator.handle if r.target_creator else "?"
        by = r.reporter.handle if r.reporter else "?"
        lines = [f"**{r.kind.replace('_', ' ')} report** by {by} · {ago(r.published)}",
                 f"> {r.reason}", "", f"- **Author:** {who}"]
        if r.community:
            lines.append(f"- **Community:** {r.community.handle}")
        if r.title:
            lines.append(f"- **Post:** {r.title}")
        lines += ["", "---", "", r.content or "_(empty)_"]
        if r.original and r.original.strip() != (r.content or "").strip() and r.kind != "post":
            lines += ["", "**Original text when reported:**", "", r.original]
        await self.query_one("#detail-md", Markdown).update("\n".join(lines))

    @on(ItemList.Selected)
    def _selected(self, event: ItemList.Selected) -> None:
        self.action_open()

    def action_open(self) -> None:
        r = self.current()
        if r and r.post_id:
            self.open_post(r.post_id, comment_id=r.comment_id)

    def action_toggle_all(self) -> None:
        self.unresolved_only = not self.unresolved_only
        self.action_refresh()

    @work(group="act")
    async def action_resolve(self) -> None:
        r = self.current()
        if r is None:
            return
        resolved = not r.resolved
        ok = await self.attempt(self.lemmy.resolve_report(r, resolved), "Report resolved" if resolved else "Report reopened")
        if ok:
            self.action_refresh(keep=(r.kind, r.id))

    @work(group="act")
    async def action_remove(self) -> None:
        r = self.current()
        if r is None:
            return
        if r.kind == "private_message":
            self.notify("Messages can't be removed; ban the sender (b) and resolve (v)", severity="warning")
            return
        removed = not r.target_removed
        reason = await self.app.push_screen_wait(
            PromptDialog(f"{'Remove' if removed else 'Restore'} this {r.kind}? Reason:", r.reason if removed else ""))
        if reason is None:
            return
        if r.kind == "post":
            ok = await self.attempt(self.lemmy.remove_post(r.post_id, removed, reason))
        else:
            ok = await self.attempt(self.lemmy.remove_comment(r.comment_id, removed, reason))
        if ok and removed and not r.resolved:
            ok = await self.attempt(self.lemmy.resolve_report(r, True))
        if ok:
            self.notify(f"{r.kind.capitalize()} {'removed' if removed else 'restored'}")
            self.action_refresh(keep=(r.kind, r.id))

    @work(group="act")
    async def action_ban(self) -> None:
        r = self.current()
        if r is None or r.target_creator is None:
            return
        who = r.target_creator
        if r.kind == "private_message" or r.community is None:
            await self._site_ban(r)
            return
        opts = await self.app.push_screen_wait(BanDialog(f"Ban {who.handle} from {r.community.handle}"))
        if opts is None:
            return
        ok = await self.attempt(self.lemmy.ban_from_community(r.community.id, who.id, True, opts.reason or r.reason,
                                                              opts.remove_data, opts.days),
                                f"Banned {who.handle} from {r.community.handle}")
        if ok and not r.resolved:
            await self.attempt(self.lemmy.resolve_report(r, True))
            self.action_refresh(keep=(r.kind, r.id))

    @work(group="act")
    async def action_site_ban(self) -> None:
        r = self.current()
        if r is not None:
            await self._site_ban(r)

    async def _site_ban(self, r: Report) -> None:
        if not self.lemmy.is_admin:
            self.notify("Only admins can ban site-wide", severity="warning")
            return
        who = r.target_creator
        if who is None:
            return
        opts = await self.app.push_screen_wait(BanDialog(f"Ban {who.handle} from the site"))
        if opts is None:
            return
        ok = await self.attempt(self.lemmy.ban_site(who.id, True, opts.reason or r.reason, opts.remove_data, opts.days),
                                f"Banned {who.handle} site-wide")
        if ok and not r.resolved:
            await self.attempt(self.lemmy.resolve_report(r, True))
            self.action_refresh(keep=(r.kind, r.id))


class ModlogScreen(LutiScreen):
    HELP_TITLE = "Modlog"
    BINDINGS = [
        Binding("R", "refresh", "Refresh"),
        Binding("x", "clear", "All communities", show=False),
    ]
    EXTRA_HELP = [("x", "show the whole site's modlog")]

    def __init__(self, community: Community | None = None):
        super().__init__()
        self.community = community
        self.pager: ModelPager[ModlogEntry] | None = None

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("", id="filter-bar")
        yield ItemList(id="modlog")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "modlog"
        self.query_one(ItemList).focus()
        self.action_refresh()

    @work(exclusive=True, group="modlog")
    async def action_refresh(self) -> None:
        where = self.community.handle if self.community else "whole site"
        self.query_one("#filter-bar", Static).update(f"[b]modlog[/] {where}")
        self.pager = self.lemmy.modlog(community_id=self.community.id if self.community else None)
        items = await self.guard(self.pager.next_page())
        if items is not None:
            await self.query_one(ItemList).set_items(items)

    @on(ItemList.NearEnd)
    @work(exclusive=True, group="modlog-more")
    async def _more(self) -> None:
        if self.pager and self.pager.has_more:
            items = await self.guard(self.pager.next_page())
            if items:
                await self.query_one(ItemList).add_items(items)

    def action_clear(self) -> None:
        if self.community:
            self.community = None
            self.action_refresh()
