"""Shared widgets and one-line renderers for luti models."""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

from rich.markup import escape
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.css.query import NoMatches
from textual.dom import NoScreen
from textual.events import Mount
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Header, Label, ListItem, ListView
from textual.widgets._header import HeaderTitle

from ..models import (
    Comment,
    Community,
    ModlogEntry,
    Notification,
    Person,
    Post,
    RegistrationApplication,
    Report,
)

# Qualified names (name@host) of starred users; the app keeps this current.
STARRED: set[str] = set()


def qualified_name(p: Person | None) -> str | None:
    if p is None:
        return None
    host = urlparse(p.ap_id).hostname if p.ap_id else None
    return f"{p.name}@{host}".lower() if host else None


def ago(iso: str) -> str:
    """'2026-11-21T03:34:37Z' -> '5m' / '3h' / '2d' / '2026-01-04'."""
    if not iso:
        return ""
    try:
        when = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except ValueError:
        return iso[:10]
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    secs = (datetime.now(timezone.utc) - when).total_seconds()
    if secs < 60:
        return "now"
    for unit, size in (("m", 60), ("h", 3600), ("d", 86400)):
        nxt = {"m": 3600, "h": 86400, "d": 86400 * 30}[unit]
        if secs < nxt:
            return f"{int(secs // size)}{unit}"
    return when.strftime("%Y-%m-%d")


def plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def one_line(text: str | None, width: int = 100) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= width else text[: width - 1] + "…"


def vote_mark(vote: str | None) -> str:
    return {"up": "[b green]▲[/]", "down": "[b red]▼[/]"}.get(vote or "", "[dim]·[/]")


def person_tag(p: Person | None, *, mod: bool = False, admin: bool = False) -> str:
    if p is None:
        return "[dim]?[/]"
    tag = f"[b cyan]{escape(p.handle)}[/]"
    if qualified_name(p) in STARRED:
        tag += " [b yellow]★[/]"
    if admin:
        tag += " [b red]A[/]"
    elif mod:
        tag += " [b green]M[/]"
    if p.bot:
        tag += " [dim]bot[/]"
    if p.banned:
        tag += " [red]banned[/]"
    return tag


def render_post(p: Post, *, show_community: bool = True) -> str:
    flags = []
    if p.featured:
        flags.append("[yellow]pinned[/]")
    if p.locked:
        flags.append("[yellow]locked[/]")
    if p.removed:
        flags.append("[red]removed[/]")
    if p.deleted:
        flags.append("[red]deleted[/]")
    if p.nsfw:
        flags.append("[red]nsfw[/]")
    kind = p.media_kind
    if kind == "image":
        flags.append("[blue]image[/]")
    elif kind == "video":
        flags.append("[blue]▶ video[/]")
    if p.saved:
        flags.append("[magenta]★[/]")
    title = f"[b]{escape(p.title)}[/]" if not p.read else escape(p.title)
    meta = [person_tag(p.creator, mod=p.creator_is_moderator, admin=p.creator_is_admin)]
    if show_community and p.community:
        meta.append(f"[green]{escape(p.community.handle)}[/]")
    meta.append(f"[dim]{ago(p.published)}[/]")
    meta.append(plural(p.comments, "comment"))
    if p.url:
        meta.append(f"[dim]{escape(one_line(p.url, 50))}[/]")
    return (f"{vote_mark(p.my_vote)} [b]{p.score:>4}[/] {' '.join(flags)} {title}\n"
            f"       {' · '.join(meta)}")


def render_comment_head(c: Comment) -> str:
    bits = [vote_mark(c.my_vote), f"[b]{c.score}[/]",
            person_tag(c.creator, mod=c.creator_is_moderator, admin=c.creator_is_admin),
            f"[dim]{ago(c.published)}[/]"]
    if c.saved:
        bits.append("[magenta]★[/]")
    if c.removed:
        bits.append("[red]removed[/]")
    if c.deleted:
        bits.append("[red]deleted[/]")
    return " ".join(bits)


def render_comment(c: Comment, *, with_post: bool = False) -> str:
    head = render_comment_head(c)
    if with_post and c.post_title:
        head += f" [dim]on[/] {escape(one_line(c.post_title, 50))}"
    return f"{head}\n  {escape(one_line(c.content))}"


def render_community(c: Community) -> str:
    sub = {"subscribed": "[green]✓ subscribed[/]", "pending": "[yellow]… pending[/]"}.get(c.subscribed, "")
    stats = []
    if c.subscribers is not None:
        stats.append(f"{c.subscribers} subscribers")
    if c.posts is not None:
        stats.append(f"{c.posts} posts")
    return f"[b green]{escape(c.handle)}[/] {escape(c.title)} {sub}\n  [dim]{' · '.join(stats)}[/]"


def render_person(p: Person) -> str:
    stats = []
    if p.post_count is not None:
        stats.append(f"{p.post_count} posts")
    if p.comment_count is not None:
        stats.append(f"{p.comment_count} comments")
    return f"{person_tag(p, admin=p.admin)} {escape(p.display_name or '')}\n  [dim]{' · '.join(stats)}[/]"


def render_notification(n: Notification) -> str:
    kind = {"reply": "[cyan]reply[/]", "mention": "[magenta]mention[/]",
            "private_message": "[yellow]message[/]", "mod_action": "[red]mod[/]"}.get(n.kind, escape(n.kind))
    unread = "[b]●[/]" if not n.read else " "
    where = ""
    if n.comment and n.comment.post_title:
        where = f" [dim]on[/] {escape(one_line(n.comment.post_title, 40))}"
    return (f"{unread} {kind} {person_tag(n.creator)}{where} [dim]{ago(n.published)}[/]\n"
            f"    {escape(one_line(n.text))}")


def render_report(r: Report) -> str:
    kind = {"post": "[cyan]post[/]", "comment": "[magenta]comment[/]", "private_message": "[yellow]message[/]"}[r.kind]
    state = "[green]resolved[/]" if r.resolved else "[b red]open[/]"
    removed = " [red](removed)[/]" if r.target_removed else ""
    where = f" in [green]{escape(r.community.handle)}[/]" if r.community else ""
    who = person_tag(r.target_creator)
    text = r.title if r.kind == "post" else r.content
    return (f"{state} {kind} by {who}{where}{removed} [dim]{ago(r.published)}[/]\n"
            f"    [b]{escape(one_line(r.reason, 60))}[/] [dim]—[/] {escape(one_line(text, 60))}"
            f"  [dim]reported by {escape(r.reporter.handle if r.reporter else '?')}[/]")


def render_application(a: RegistrationApplication) -> str:
    state = {"pending": "[b yellow]pending[/]", "approved": "[green]approved[/]", "denied": "[red]denied[/]"}[a.status]
    email = f" [dim]{escape(a.email)}[/]" if a.email else ""
    return f"{state} {person_tag(a.creator)}{email} [dim]{ago(a.published)}[/]\n    {escape(one_line(a.answer))}"


def render_modlog(m: ModlogEntry) -> str:
    who = escape(m.moderator.handle) if m.moderator else "[dim]mod[/]"
    reason = f" [dim]— {escape(one_line(m.reason, 60))}[/]" if m.reason else ""
    return f"[dim]{ago(m.when):>10}[/] [b]{who}[/] {escape(m.description)}{reason}"


def render_any(obj: Any) -> str:
    if isinstance(obj, Post):
        return render_post(obj)
    if isinstance(obj, Comment):
        return render_comment(obj, with_post=True)
    if isinstance(obj, Community):
        return render_community(obj)
    if isinstance(obj, Person):
        return render_person(obj)
    if isinstance(obj, Notification):
        return render_notification(obj)
    if isinstance(obj, Report):
        return render_report(obj)
    if isinstance(obj, RegistrationApplication):
        return render_application(obj)
    if isinstance(obj, ModlogEntry):
        return render_modlog(obj)
    return escape(str(obj))


class Row(ListItem):
    """A list row that carries a model object (and, for posts, an optional thumbnail)."""

    def __init__(self, obj: Any, markup: str | None = None):
        super().__init__()
        self.obj = obj
        self.markup = markup

    def compose(self) -> ComposeResult:
        label = Label(self.markup if self.markup is not None else render_any(self.obj), markup=True)
        thumb = self._thumbnail()
        if thumb is None:
            yield label
        else:
            with Horizontal(classes="row-with-thumb"):
                yield thumb
                yield label

    def _thumbnail(self):
        from . import media

        app = self.app
        if not isinstance(self.obj, Post) or not getattr(app, "show_thumbnails", lambda: False)():
            return None
        url = media.thumbnail_for(self.obj)
        if not url:
            return None
        if self.obj.nsfw and not app.nsfw_revealed(True):  # type: ignore[attr-defined]
            return None
        return media.Thumbnail(url, app.image_cache)  # type: ignore[attr-defined]

    def refresh_obj(self, obj: Any) -> None:
        self.obj = obj
        self.query(Label).last().update(render_any(obj))


class ItemList(ListView):
    """ListView with vim keys, model rows and a near-the-end signal for paging."""

    BINDINGS = [
        Binding("j", "cursor_down", "Down", show=False),
        Binding("k", "cursor_up", "Up", show=False),
        Binding("g", "first", "Top", show=False),
        Binding("G", "last", "Bottom", show=False),
        Binding("ctrl+d", "page_down", "Page down", show=False),
        Binding("ctrl+u", "page_up", "Page up", show=False),
    ]

    class NearEnd(Message):
        def __init__(self, item_list: "ItemList"):
            super().__init__()
            self.item_list = item_list

        @property
        def control(self) -> "ItemList":
            return self.item_list

    def action_first(self) -> None:
        if len(self):
            self.index = 0

    def action_last(self) -> None:
        if len(self):
            self.index = len(self) - 1

    @property
    def current(self) -> Any:
        child = self.highlighted_child
        return child.obj if isinstance(child, Row) else None

    def watch_index(self, old: int | None, new: int | None) -> None:  # type: ignore[override]
        super().watch_index(old, new)
        if new is not None and len(self) and new >= len(self) - 3:
            self.post_message(self.NearEnd(self))

    async def set_items(self, objs: list[Any]) -> None:
        await self.clear()
        await self.extend([Row(o) for o in objs])
        if objs:
            self.index = 0

    async def add_items(self, objs: list[Any]) -> None:
        await self.extend([Row(o) for o in objs])
        if self.index is None and len(self):
            self.index = 0

    def update_current(self, obj: Any) -> None:
        child = self.highlighted_child
        if isinstance(child, Row):
            child.refresh_obj(obj)

    def rerender(self) -> None:
        for child in self.children:
            if isinstance(child, Row) and child.markup is None:
                labels = child.query(Label)
                if labels:
                    labels.last().update(render_any(child.obj))

    @property
    def objects(self) -> list[Any]:
        return [c.obj for c in self.children if isinstance(c, Row)]


class SafeHeader(Header):
    """Header that tolerates title changes while it is still composing or being removed.

    Textual's Header updates its HeaderTitle from a watcher; when the app title changes
    while a screen is mid-mount or mid-removal, the child isn't there and the stock
    widget raises NoMatches, which takes the whole app down.
    """

    def _on_mount(self, event: Mount) -> None:
        # Textual dispatches _on_mount up the MRO; stop it before the stock Header
        # registers its own (unguarded) watchers, and run Widget's handler ourselves.
        event.prevent_default()
        Widget._on_mount(self, event)

        async def set_title() -> None:
            try:
                self.query_one(HeaderTitle).update(self.format_title())
            except (NoScreen, NoMatches):
                pass

        self.watch(self.app, "title", set_title)
        self.watch(self.app, "sub_title", set_title)
        self.watch(self.screen, "title", set_title)
        self.watch(self.screen, "sub_title", set_title)
