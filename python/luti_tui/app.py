"""luti-tui application and command-line entry point."""
from __future__ import annotations

import argparse
import os
import sys

from textual import work
from textual.app import App
from textual.binding import Binding
from textual.css.query import NoMatches

from . import __version__
from .api import Lemmy
from .client import AuthError, LemmyClient, LutiError
from .config import Profile, list_profiles, valid_profile_name
from .screens.base import LutiScreen
from .screens.dialogs import HelpScreen

CSS = """
Screen { background: $surface; }
#filter-bar, #reg-bar { height: 1; padding: 0 1; background: $boost; color: $text-muted; }
ItemList { height: 1fr; }
ItemList > ListItem { padding: 0 1; height: auto; }
ItemList > ListItem Label { width: 1fr; }
#detail { height: 12; border-top: solid $primary; padding: 0 1; }
#login { height: 1fr; }
#profiles-pane { width: 34; border-right: solid $primary; padding: 0 1; }
#profiles { height: 1fr; }
#login-form { padding: 1 2; }
#login-form Input, #login-form Select { width: 60; margin-bottom: 1; }
#login-status { margin-top: 1; height: auto; }
.buttons { height: auto; margin-top: 1; }
.buttons Button { margin-right: 2; }
#post-layout { height: 1fr; }
#post-body { height: auto; max-height: 40%; padding: 0 1; border-bottom: solid $primary; }
#post-head { height: auto; }
#post-md { margin: 0; }
#comments { height: 1fr; }
#comment-detail { height: 10; border-top: solid $primary; padding: 0 1; }
#compose { height: 1fr; padding: 0 1; }
#compose Input { margin-bottom: 0; }
#compose-body { height: 1fr; }
#c-body { width: 1fr; height: 1fr; }
#c-preview-pane { width: 1fr; height: 1fr; border-left: solid $primary; padding: 0 1; }
#compose-status { height: auto; }
#person-head { height: auto; padding: 0 1; border-bottom: solid $primary; }
#search-bar { height: auto; }
#query { width: 1fr; }
#search-type, #search-listing { width: 22; }
.form { height: auto; padding: 1 2; }
.form Input, .form Select { width: 60; }
#bans-title { padding: 0 2; }
#recent-bans { height: 1fr; }
ModalScreen { align: center middle; }
.dialog { width: 72; height: auto; max-height: 90%; padding: 1 2; border: thick $primary; background: $panel; }
.dialog-title { margin-bottom: 1; width: 1fr; }
.dialog-buttons { height: auto; margin-top: 1; }
.dialog-buttons Button { margin-right: 2; }
.dialog.help { width: 80; height: 90%; }
"""


class LutiApp(App):
    TITLE = "luti"
    CSS = CSS
    BINDINGS = [
        Binding("question_mark", "help", "Help", key_display="?"),
        Binding("f1", "help", "Help", show=False),
        Binding("F", "goto('feed')", "Feed", show=False),
        Binding("I", "goto('inbox')", "Inbox", show=False),
        Binding("C", "goto('communities')", "Communities", show=False),
        Binding("slash", "goto('search')", "Search", show=False, key_display="/"),
        Binding("U", "goto('me')", "Me", show=False),
        Binding("M", "goto('modqueue')", "Mod queue", show=False),
        Binding("O", "goto('modlog')", "Modlog", show=False),
        Binding("A", "goto('admin')", "Admin", show=False),
        Binding("P", "profiles", "Profiles", show=False),
        Binding("ctrl+q", "quit", "Quit", show=False, priority=True),
    ]

    def __init__(self, profile: str | None = None, instance: str | None = None, api: str | None = None):
        super().__init__()
        self.profile_name = profile
        self.instance_override = instance
        self.api_override = api
        self.profile: Profile | None = None
        self.lemmy: Lemmy | None = None
        self.unread_text = ""

    # -- start-up ----------------------------------------------------------------
    def on_mount(self) -> None:
        self.set_interval(90, self.refresh_unread)
        self.boot()

    @work(exclusive=True, group="boot")
    async def boot(self) -> None:
        from .screens.login import LoginScreen

        name = self.profile_name
        if name is None:
            names = list_profiles()
            name = os.environ.get("LUTI_PROFILE") or ("default" if "default" in names or not names else names[0])
        if not valid_profile_name(name):
            self.push_screen(LoginScreen(message=f"Invalid profile name {name!r}"))
            return
        p = Profile.load(name)
        if self.instance_override:
            p.instance = self.instance_override
        if self.api_override:
            p.api = self.api_override
        token = p.read_token() if p.exists() else None
        if not (p.instance and token):
            self.push_screen(LoginScreen(profile=name if p.exists() or self.profile_name else None))
            return
        lemmy = Lemmy(LemmyClient(p.instance, token=token, api=p.api))
        try:
            await lemmy.connect()
            if await lemmy.load_me() is None:
                raise AuthError("account.get", 401, "not_logged_in")
        except AuthError:
            await lemmy.aclose()
            self.push_screen(LoginScreen(profile=name, message="Your session has expired. Log in again."))
            return
        except (LutiError, ValueError) as e:
            await lemmy.aclose()
            self.push_screen(LoginScreen(profile=name, message=str(e)))
            return
        await self.start_session(p, lemmy)

    async def start_session(self, profile: Profile | None, lemmy: Lemmy) -> None:
        """Make `lemmy` the active session and show the feed."""
        old = self.lemmy
        self.profile = profile
        self.lemmy = lemmy
        # Run the screen switch on the app, not in the caller's worker: popping
        # the login screen would cancel a worker that belongs to it.
        self.call_later(self._enter_feed, old if old is not lemmy else None)

    async def _enter_feed(self, old: Lemmy | None) -> None:
        from .screens.feed import FeedScreen

        while len(self.screen_stack) > 1:
            self.pop_screen()
        await self.push_screen(FeedScreen())
        self.refresh_title()
        self.refresh_unread()
        if old is not None:
            await old.aclose()

    def refresh_title(self) -> None:
        lemmy = self.lemmy
        if lemmy is None:
            self.title = "luti"
            return
        host = lemmy.client.instance.split("://", 1)[-1]
        who = lemmy.me.person.name if lemmy.me else "anonymous"
        ver = lemmy.client.server_version or lemmy.version
        title = f"luti · {who}@{host} · {ver}"
        try:
            self.title = f"{title} · {self.unread_text}" if self.unread_text else title
        except NoMatches:
            # A Header on a screen that is being removed reacted to the change;
            # try again once the screen stack has settled.
            self.call_after_refresh(self.refresh_title)

    @work(exclusive=True, group="unread")
    async def refresh_unread(self) -> None:
        lemmy = self.lemmy
        if lemmy is None or not lemmy.client.token:
            return
        try:
            counts = await lemmy.unread()
        except LutiError:
            return
        parts = [f"inbox {counts.inbox}"]
        if lemmy.is_mod:
            parts.append(f"reports {counts.reports}")
        if lemmy.is_admin:
            parts.append(f"applications {counts.applications}")
        self.unread_text = " · ".join(parts)
        self.refresh_title()

    # -- navigation ----------------------------------------------------------------
    def action_help(self) -> None:
        if isinstance(self.screen, HelpScreen):
            return
        self.push_screen(HelpScreen(self.screen))

    def action_profiles(self) -> None:
        from .screens.login import LoginScreen

        if isinstance(self.screen, LoginScreen):
            return
        self.push_screen(LoginScreen(profile=self.profile.name if self.profile else None))

    def action_goto(self, section: str) -> None:
        from .screens.admin import AdminScreen
        from .screens.community import CommunitiesScreen
        from .screens.inbox import InboxScreen
        from .screens.mod import ModlogScreen, ModQueueScreen
        from .screens.person import PersonScreen
        from .screens.search import SearchScreen

        if self.lemmy is None or not isinstance(self.screen, LutiScreen) or type(self.screen).__name__ == "LoginScreen":
            return
        authed = bool(self.lemmy.client.token)
        if section in ("inbox", "me", "modqueue", "admin") and not authed:
            self.notify("Log in first (P)", severity="warning")
            return
        if section == "modqueue" and not self.lemmy.is_mod:
            self.notify("You don't moderate any communities", severity="warning")
            return
        if section == "admin" and not self.lemmy.is_admin:
            self.notify("You are not an admin on this instance", severity="warning")
            return
        # back to the feed, then open the section on top of it
        while len(self.screen_stack) > 2:
            self.pop_screen()
        screen = {
            "feed": None,
            "inbox": InboxScreen,
            "communities": CommunitiesScreen,
            "search": SearchScreen,
            "modqueue": ModQueueScreen,
            "modlog": ModlogScreen,
            "admin": AdminScreen,
        }.get(section)
        if section == "me" and self.lemmy.me:
            self.push_screen(PersonScreen(username=self.lemmy.me.person.name))
        elif screen is not None:
            self.push_screen(screen())

    async def on_unmount(self) -> None:
        if self.lemmy is not None:
            await self.lemmy.aclose()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="luti-tui", description="A terminal client for Lemmy 0.19 and 1.0.")
    parser.add_argument("-p", "--profile", help="profile name (default: $LUTI_PROFILE, 'default' or the first profile)")
    parser.add_argument("-i", "--instance", help="instance URL, overriding the profile")
    parser.add_argument("--api", choices=["v3", "v4"], help="skip version detection")
    parser.add_argument("--list-profiles", action="store_true", help="list profiles and exit")
    parser.add_argument("--spec-path", action="store_true", help="print the endpoint spec in use and exit")
    parser.add_argument("-V", "--version", action="version", version=f"luti-tui {__version__}")
    args = parser.parse_args(argv)
    if args.list_profiles:
        for name in list_profiles():
            p = Profile.load(name)
            print(f"{name}\t{p.username}@{p.instance}\t{p.api or 'auto'}")
        return 0
    if args.spec_path:
        from .spec import load_spec, spec_path

        path = spec_path()
        print(f"{path} ({len(load_spec()['ops'])} ops)")
        return 0
    if args.profile and not valid_profile_name(args.profile):
        parser.error(f"invalid profile name {args.profile!r}")
    LutiApp(profile=args.profile, instance=args.instance, api=args.api).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
