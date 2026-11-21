"""Compose posts, comments and private messages with a Markdown preview."""
from __future__ import annotations

from typing import Any

from rich.markup import escape
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import Screen
from textual.widgets import Footer, Input, Label, Markdown, Static, TextArea

from ...client import LutiError
from ..widgets import SafeHeader, one_line


class ComposeScreen(Screen):
    """kind: post / comment / message. Dismisses with the created object, or None."""

    HELP_TITLE = "Compose"
    BINDINGS = [
        Binding("ctrl+s", "submit", "Send"),
        Binding("escape", "cancel", "Cancel"),
        Binding("ctrl+p", "toggle_preview", "Preview"),
    ]
    EXTRA_HELP = [("tab", "next field"), ("", "Markdown is supported; the preview updates as you type")]

    def __init__(self, kind: str, *, community: str = "", post_id: int | None = None, parent_id: int | None = None,
                 recipient: str = "", recipient_id: int | None = None, context: str = ""):
        super().__init__()
        self.kind = kind
        self.community = community
        self.post_id = post_id
        self.parent_id = parent_id
        self.recipient = recipient
        self.recipient_id = recipient_id
        self.context = context
        self._busy = False

    # factories
    @classmethod
    def post(cls, community: str = "") -> "ComposeScreen":
        return cls("post", community=community)

    @classmethod
    def comment(cls, post_id: int, parent_id: int | None, context: str = "") -> "ComposeScreen":
        return cls("comment", post_id=post_id, parent_id=parent_id, context=context)

    @classmethod
    def message(cls, recipient: str, recipient_id: int | None = None, context: str = "") -> "ComposeScreen":
        return cls("message", recipient=recipient, recipient_id=recipient_id, context=context)

    def compose(self) -> ComposeResult:
        yield SafeHeader()
        with Vertical(id="compose"):
            title = {"post": "New post", "comment": "Reply" if self.parent_id else "Comment",
                     "message": "Private message"}[self.kind]
            yield Label(f"[b]{title}[/]  [dim]ctrl+s send · esc cancel · ctrl+p preview[/]")
            if self.context:
                yield Static(f"[dim]↳ {escape(one_line(self.context, 120))}[/]", id="compose-context")
            if self.kind == "post":
                yield Input(self.community, placeholder="Community (name or name@instance)", id="c-community")
                yield Input(placeholder="Title", id="c-title")
                yield Input(placeholder="URL (optional)", id="c-url")
            elif self.kind == "message":
                yield Input(self.recipient, placeholder="To (username or user@instance)", id="c-recipient")
            with Horizontal(id="compose-body"):
                yield TextArea(id="c-body", soft_wrap=True, show_line_numbers=False,
                               placeholder="Write here (Markdown)…")
                with VerticalScroll(id="c-preview-pane"):
                    yield Markdown("", id="c-preview")
            yield Static("", id="compose-status")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "compose"
        if self.kind == "post":
            self.query_one("#c-title" if self.community else "#c-community", Input).focus()
        elif self.kind == "message" and not self.recipient:
            self.query_one("#c-recipient", Input).focus()
        else:
            self.query_one(TextArea).focus()

    @on(TextArea.Changed)
    async def _changed(self, event: TextArea.Changed) -> None:
        await self.query_one("#c-preview", Markdown).update(event.text_area.text)

    def action_toggle_preview(self) -> None:
        pane = self.query_one("#c-preview-pane")
        pane.display = not pane.display

    def action_cancel(self) -> None:
        self.dismiss(None)

    def status(self, text: str) -> None:
        self.query_one("#compose-status", Static).update(text)

    @work(exclusive=True)
    async def action_submit(self) -> None:
        if self._busy:
            return
        lemmy = self.app.lemmy  # type: ignore[attr-defined]
        body = self.query_one(TextArea).text.strip()
        self._busy = True
        self.status("Sending…")
        try:
            result: Any
            if self.kind == "post":
                name = self.query_one("#c-community", Input).value.strip().lstrip("!")
                title = self.query_one("#c-title", Input).value.strip()
                url = self.query_one("#c-url", Input).value.strip() or None
                if not name or not title:
                    self.status("[red]Community and title are required[/]")
                    return
                community = await lemmy.community(name=name)
                result = await lemmy.create_post(community.id, title, body or None, url)
            elif self.kind == "comment":
                if not body:
                    self.status("[red]Write something first[/]")
                    return
                result = await lemmy.create_comment(self.post_id, body, self.parent_id)
            else:
                if not body:
                    self.status("[red]Write something first[/]")
                    return
                rid = self.recipient_id
                who = self.query_one("#c-recipient", Input).value.strip().lstrip("@")
                if rid is None or who != self.recipient:
                    if not who:
                        self.status("[red]Who is it for?[/]")
                        return
                    rid = (await lemmy.find_person(who)).id
                result = await lemmy.send_pm(rid, body)
        except LutiError as e:
            self.status(f"[red]{escape(str(e))}[/]")
            return
        finally:
            self._busy = False
        self.notify({"post": "Post created", "comment": "Comment posted", "message": "Message sent"}[self.kind])
        self.dismiss(result)
