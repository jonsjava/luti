"""Modal dialogs: confirm, prompt, ban options and the ? help overlay."""
from __future__ import annotations

from dataclasses import dataclass

from rich.markup import escape
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, Checkbox, Input, Label, Static


class ConfirmDialog(ModalScreen[bool]):
    """Yes/no question. `danger=True` styles the confirm button red."""

    BINDINGS = [Binding("escape,n", "cancel", "Cancel"), Binding("y", "confirm", "Yes")]

    def __init__(self, question: str, confirm_label: str = "Yes", danger: bool = False):
        super().__init__()
        self.question = question
        self.confirm_label = confirm_label
        self.danger = danger

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label(self.question, classes="dialog-title")
            with Horizontal(classes="dialog-buttons"):
                yield Button(self.confirm_label, id="confirm", variant="error" if self.danger else "primary")
                yield Button("Cancel", id="cancel")

    def on_mount(self) -> None:
        self.query_one("#cancel" if self.danger else "#confirm", Button).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)


class PromptDialog(ModalScreen["str | None"]):
    """Ask for one line of text. Returns None on cancel."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, question: str, value: str = "", placeholder: str = "", allow_empty: bool = True):
        super().__init__()
        self.question = question
        self.value = value
        self.placeholder = placeholder
        self.allow_empty = allow_empty

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label(self.question, classes="dialog-title")
            yield Input(self.value, placeholder=self.placeholder, id="prompt-input")
            with Horizontal(classes="dialog-buttons"):
                yield Button("OK", id="ok", variant="primary")
                yield Button("Cancel", id="cancel")

    def on_mount(self) -> None:
        self.query_one(Input).focus()

    def _submit(self) -> None:
        value = self.query_one(Input).value.strip()
        if not value and not self.allow_empty:
            self.notify("A value is required", severity="warning")
            return
        self.dismiss(value)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self._submit()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ok":
            self._submit()
        else:
            self.dismiss(None)

    def action_cancel(self) -> None:
        self.dismiss(None)


@dataclass
class BanOptions:
    reason: str
    days: float | None
    remove_data: bool


class BanDialog(ModalScreen["BanOptions | None"]):
    """Reason, optional duration in days and remove-content flag for a ban."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, title: str, unban: bool = False):
        super().__init__()
        self.title_text = title
        self.unban = unban

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog"):
            yield Label(self.title_text, classes="dialog-title")
            yield Input(placeholder="Reason", id="ban-reason")
            if not self.unban:
                yield Input(placeholder="Days (empty = permanent)", id="ban-days", type="number")
            yield Checkbox("Restore content" if self.unban else "Remove their content", id="ban-remove")
            with Horizontal(classes="dialog-buttons"):
                yield Button("Unban" if self.unban else "Ban", id="ok", variant="warning" if self.unban else "error")
                yield Button("Cancel", id="cancel")

    def on_mount(self) -> None:
        self.query_one("#ban-reason", Input).focus()

    def _submit(self) -> None:
        days: float | None = None
        if not self.unban:
            raw = self.query_one("#ban-days", Input).value.strip()
            if raw:
                try:
                    days = float(raw)
                except ValueError:
                    self.notify("Days must be a number", severity="warning")
                    return
                if days <= 0:
                    days = None
        self.dismiss(BanOptions(self.query_one("#ban-reason", Input).value.strip(), days,
                                self.query_one("#ban-remove", Checkbox).value))

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self._submit()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ok":
            self._submit()
        else:
            self.dismiss(None)

    def action_cancel(self) -> None:
        self.dismiss(None)


GLOBAL_HELP = [
    ("? / F1", "this help (F1 also works while typing)"),
    ("F", "feed (home)"),
    ("T", "stargaze: new posts from starred users"),
    ("I", "inbox"),
    ("C", "communities"),
    ("/", "search"),
    ("U", "my profile"),
    ("M", "mod queue (moderators)"),
    ("O", "modlog"),
    ("A", "admin (admins)"),
    ("P", "switch profile / log in"),
    ("esc / q", "back (q on the feed quits)"),
    ("j / k", "move down / up"),
    ("g / G", "first / last item"),
    ("ctrl+p", "command palette (all sections)"),
    ("ctrl+q", "quit"),
]


class HelpScreen(ModalScreen[None]):
    """Key bindings for the global app and the screen underneath."""

    BINDINGS = [Binding("escape,q,question_mark", "close", "Close")]

    def __init__(self, screen: Screen):
        super().__init__()
        self.under = screen

    def compose(self) -> ComposeResult:
        rows = []
        title = getattr(self.under, "HELP_TITLE", None) or type(self.under).__name__.replace("Screen", "")
        seen = set()
        local = []
        for b in getattr(self.under, "BINDINGS", []):
            if not isinstance(b, Binding) or not b.description:
                continue
            key = b.key_display or b.key.replace("question_mark", "?").replace(",", " / ")
            if key in seen:
                continue
            seen.add(key)
            local.append((key, b.description))
        local.extend(getattr(self.under, "EXTRA_HELP", []))
        if local:
            rows.append(f"[b u]{escape(title)}[/]")
            rows += [f"  [b cyan]{escape(k):<12}[/] {escape(d)}" for k, d in local]
            rows.append("")
        rows.append("[b u]Everywhere[/]")
        rows += [f"  [b cyan]{escape(k):<12}[/] {escape(d)}" for k, d in GLOBAL_HELP]
        with Vertical(classes="dialog help"):
            yield Label("luti — keys", classes="dialog-title")
            with VerticalScroll():
                yield Static("\n".join(rows), markup=True, id="help-text")
            yield Label("[dim]esc to close[/]")

    def action_close(self) -> None:
        self.dismiss(None)
