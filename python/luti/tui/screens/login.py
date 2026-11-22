"""Login and profile picker."""
from __future__ import annotations

from rich.markup import escape
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import (
    Button,
    Checkbox,
    Footer,
    Input,
    Label,
    ListItem,
    ListView,
    Select,
    Static,
)

from ...api import Lemmy
from ...client import AuthError, LemmyClient, LutiError, MfaRequired, same_instance
from ...config import Profile, list_profiles, valid_profile_name
from ..widgets import SafeHeader
from .base import LutiScreen


class LoginScreen(LutiScreen):
    HELP_TITLE = "Log in"
    BINDINGS = [
        Binding("escape", "back", "Back"),
        Binding("ctrl+s", "login", "Log in"),
        Binding("ctrl+n", "new_profile", "New profile"),
    ]
    EXTRA_HELP = [("enter", "on a profile: use its saved session"), ("tab", "next field")]

    def __init__(self, profile: str | None = None, message: str | None = None, instance: str | None = None):
        super().__init__()
        self.initial = profile
        self.message = message
        self.instance = instance  # from luti-tui -i: prefills the form

    def compose(self) -> ComposeResult:
        yield SafeHeader()
        with Horizontal(id="login"):
            with Vertical(id="profiles-pane"):
                yield Label("[b]Profiles[/]")
                yield ListView(id="profiles")
                yield Static("[dim]enter: use saved session\nctrl+n: new profile[/]")
            with VerticalScroll(id="login-form"):
                yield Label("[b]Log in to Lemmy[/]", id="login-title")
                if self.message:
                    yield Static(f"[yellow]{escape(self.message)}[/]", id="login-message")
                yield Label("Profile name")
                yield Input(placeholder="default", id="profile")
                yield Label("Instance")
                yield Input(placeholder="https://lemmy.example", id="instance")
                yield Label("Username or email")
                yield Input(id="username")
                yield Label("Password (never stored)")
                yield Input(password=True, id="password")
                yield Checkbox("Two-factor authentication", id="mfa")
                yield Input(placeholder="2FA code", id="totp", restrict=r"[0-9]*", max_length=8)
                yield Label("API version")
                yield Select([("Auto-detect", "auto"), ("v4 (Lemmy 1.0)", "v4"), ("v3 (Lemmy 0.19)", "v3")],
                             value="auto", allow_blank=False, id="api")
                with Horizontal(classes="buttons"):
                    yield Button("Log in", id="login-btn", variant="primary")
                    yield Button("Use saved session", id="session-btn")
                    yield Button("Browse without login", id="anon-btn")
                yield Static("", id="login-status")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "luti"
        self.sub_title = "log in"
        lv = self.query_one("#profiles", ListView)
        names = list_profiles()
        for name in names:
            p = Profile.load(name)
            lv.append(ListItem(Label(f"[b]{escape(name)}[/]\n[dim]{escape(p.username)}@{escape(p.instance)}[/]"), name=name))
        start = self.initial if self.initial else (names[0] if names else None)
        if start:
            self.fill(start)
            if start in names:
                lv.index = names.index(start)
        else:
            self.query_one("#profile", Input).value = "default"
        if self.instance:
            self.query_one("#instance", Input).value = self.instance
        self.query_one("#totp").display = self.query_one("#mfa", Checkbox).value
        focus = "#password" if self.query_one("#username", Input).value else "#instance"
        self.query_one(focus, Input).focus()

    def fill(self, name: str) -> None:
        p = Profile.load(name)
        self.query_one("#profile", Input).value = name
        self.query_one("#instance", Input).value = p.instance
        self.query_one("#username", Input).value = p.username
        self.query_one("#mfa", Checkbox).value = p.mfa
        self.query_one("#api", Select).value = p.api or "auto"
        self.query_one("#session-btn", Button).disabled = not p.read_token()

    @on(ListView.Highlighted, "#profiles")
    def _highlight(self, event: ListView.Highlighted) -> None:
        if event.item is not None and event.item.name:
            self.fill(event.item.name)

    @on(ListView.Selected, "#profiles")
    def _selected(self, event: ListView.Selected) -> None:
        if event.item.name:
            self.fill(event.item.name)
            self.use_session()

    @on(Checkbox.Changed, "#mfa")
    def _mfa(self, event: Checkbox.Changed) -> None:
        self.query_one("#totp").display = event.value

    @on(Input.Submitted)
    def _submitted(self, event: Input.Submitted) -> None:
        if event.input.id in ("password", "totp"):
            self.action_login()
        else:
            self.focus_next()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "login-btn":
            self.action_login()
        elif event.button.id == "session-btn":
            self.use_session()
        elif event.button.id == "anon-btn":
            self.browse_anonymously()

    def action_new_profile(self) -> None:
        for wid in ("#instance", "#username", "#password", "#totp"):
            self.query_one(wid, Input).value = ""
        self.query_one("#profile", Input).value = ""
        self.query_one("#mfa", Checkbox).value = False
        self.query_one("#api", Select).value = "auto"
        self.query_one("#profile", Input).focus()

    def status(self, text: str) -> None:
        self.query_one("#login-status", Static).update(text)

    def _form_profile(self) -> Profile | None:
        name = self.query_one("#profile", Input).value.strip() or "default"
        if not valid_profile_name(name):
            self.status("[red]Profile names may use letters, digits, . _ @ -[/]")
            return None
        p = Profile.load(name)
        p.instance = self.query_one("#instance", Input).value.strip()
        p.username = self.query_one("#username", Input).value.strip()
        p.mfa = self.query_one("#mfa", Checkbox).value
        api = self.query_one("#api", Select).value
        p.api = api if api in ("v3", "v4") else None
        if not p.instance:
            self.status("[red]Enter an instance[/]")
            return None
        return p

    @work(exclusive=True, group="login")
    async def action_login(self) -> None:
        p = self._form_profile()
        if p is None:
            return
        password = self.query_one("#password", Input).value
        if not p.username or not password:
            self.status("[red]Enter a username and password[/]")
            return
        totp = self.query_one("#totp", Input).value.strip() or None
        self.status("Logging in…")
        try:
            lemmy = Lemmy(LemmyClient(p.instance, api=p.api))
        except ValueError as e:
            self.status(f"[red]{escape(str(e))}[/]")
            return
        try:
            token = await lemmy.login(p.username, password, totp)
            await lemmy.load_me()
        except MfaRequired:
            await lemmy.aclose()
            self.query_one("#mfa", Checkbox).value = True
            self.query_one("#totp").display = True
            self.query_one("#totp", Input).focus()
            self.status("[yellow]Enter your 2FA code[/]")
            return
        except AuthError as e:
            await lemmy.aclose()
            self.status(f"[red]Login failed: {escape(e.message or e.error)}[/]")
            return
        except (LutiError, ValueError) as e:
            await lemmy.aclose()
            self.status(f"[red]{escape(str(e))}[/]")
            return
        p.instance = lemmy.client.instance
        p.save()
        p.write_token(token)
        self.query_one("#password", Input).value = ""
        self.status("")
        await self.luti.start_session(p, lemmy)

    @work(exclusive=True, group="login")
    async def use_session(self) -> None:
        p = self._form_profile()
        if p is None:
            return
        token = p.read_token()
        if token and not same_instance(Profile.load(p.name).instance, p.instance):
            self.status("[yellow]The saved session is for another instance; enter the password[/]")
            self.query_one("#password", Input).focus()
            return
        if not token:
            self.status("[yellow]No saved session for this profile; enter the password[/]")
            self.query_one("#password", Input).focus()
            return
        self.status("Checking saved session…")
        lemmy = Lemmy(LemmyClient(p.instance, token=token, api=p.api))
        try:
            await lemmy.connect()
            me = await lemmy.load_me()
            if me is None:
                raise AuthError("account.get", 401, "not_logged_in")
        except AuthError:
            await lemmy.aclose()
            self.status("[yellow]Saved session expired; enter the password[/]")
            self.query_one("#password", Input).focus()
            return
        except LutiError as e:
            await lemmy.aclose()
            self.status(f"[red]{escape(str(e))}[/]")
            return
        p.save()
        self.status("")
        await self.luti.start_session(p, lemmy)

    @work(exclusive=True, group="login")
    async def browse_anonymously(self) -> None:
        instance = self.query_one("#instance", Input).value.strip()
        if not instance:
            self.status("[red]Enter an instance[/]")
            return
        api = self.query_one("#api", Select).value
        lemmy = Lemmy(LemmyClient(instance, api=api if api in ("v3", "v4") else None))
        try:
            await lemmy.connect()
        except (LutiError, ValueError) as e:
            await lemmy.aclose()
            self.status(f"[red]{escape(str(e))}[/]")
            return
        await self.luti.start_session(None, lemmy)
