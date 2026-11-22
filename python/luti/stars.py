"""Stargaze: a client-side queue of new posts from favorite users.

Lemmy has no "follow a user", so luti keeps favorites itself, in files shared
with luti's Bash CLI (same format, same paths on every OS):

    $XDG_CONFIG_HOME/luti/<profile>/stars       one user per line, name@instance.host,
                                                 sorted and unique; blank lines and # comments allowed
    $XDG_STATE_HOME/luti/<profile>/stargaze      name@instance.host<TAB>last_seen_post_id

Post ids are local to the home instance and only increase, so a post is unread
when its id is greater than last_seen. A newly starred user's last_seen starts
at their newest post, so their history doesn't flood the queue.
"""
from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import TYPE_CHECKING, Any
from urllib.parse import urlparse

from .config import Profile, atomic_write, config_root, state_root, valid_profile_name
from .errors import ApiError
from .models import Post

if TYPE_CHECKING:
    from .api import Lemmy
    from .client import LemmyClient

log = logging.getLogger("luti")

CONCURRENCY = 4
PAGE_SIZE = 20
MAX_PAGES = 5


def qualify(user: str, home_domain: str | None) -> str:
    """'alice' -> 'alice@home.domain'; '@bob@far.away' -> 'bob@far.away'. Lowercased."""
    user = user.strip().lstrip("@").lower()
    if not user:
        raise ValueError("empty user name")
    if "@" not in user:
        if not home_domain:
            raise ValueError(f"{user!r} needs an instance (name@instance.host)")
        user = f"{user}@{home_domain.lower()}"
    name, _, host = user.partition("@")
    if not name or not host or "@" in host or any(c.isspace() for c in user):
        raise ValueError(f"not a user handle: {user!r}")
    return user


def parse_stars(text: str) -> list[str]:
    users = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            users.append(line.lstrip("@").lower())
    return sorted(set(users))


def format_stars(users: list[str], header: list[str] | None = None) -> str:
    """Sorted, unique names; `header` comment lines (as the Bash CLI keeps them) go first."""
    return "".join(f"{h}\n" for h in header or []) + "".join(f"{u}\n" for u in sorted(set(users)))


def stars_header(text: str) -> list[str]:
    """The leading `#` comment lines of a stars file (blank lines between them dropped)."""
    out = []
    for line in text.splitlines():
        if line.strip().startswith("#"):
            out.append(line.rstrip())
        elif line.strip():
            break
    return out


def parse_state(text: str) -> dict[str, int]:
    state: dict[str, int] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        user, _, seen = line.partition("\t")
        if not seen:  # tolerate space-separated lines
            user, _, seen = line.strip().partition(" ")
        try:
            state[user.strip().lower()] = int(seen.strip())
        except ValueError:
            continue
    return state


def format_state(state: dict[str, int]) -> str:
    return "".join(f"{u}\t{state[u]}\n" for u in sorted(state))


def home_domain_of(site: dict | None) -> str | None:
    """The federation domain of an instance from its GET site response."""
    site_obj = ((site or {}).get("site_view") or {}).get("site") or {}
    ap = site_obj.get("ap_id") or site_obj.get("actor_id") or ""
    return urlparse(ap).hostname if ap else None


class Stars:
    """Favorite users of one profile, and their stargaze read state."""

    def __init__(self, profile: str | Profile = "default"):
        name = profile.name if isinstance(profile, Profile) else profile
        if not valid_profile_name(name):
            raise ValueError(f"invalid profile name: {name!r}")
        self.profile = name
        self.warnings: list[str] = []

    @property
    def stars_file(self) -> Path:
        return config_root() / self.profile / "stars"

    @property
    def state_file(self) -> Path:
        return state_root() / self.profile / "stargaze"

    # -- favorites -------------------------------------------------------------
    def list(self) -> list[str]:
        if not self.stars_file.is_file():
            return []
        return parse_stars(self.stars_file.read_text(encoding="utf-8"))

    def _header(self) -> list[str]:
        return stars_header(self.stars_file.read_text(encoding="utf-8")) if self.stars_file.is_file() else []

    def __contains__(self, user: str) -> bool:
        return user.lstrip("@").lower() in self.list()

    def add(self, user: str, home_domain: str | None = None) -> str:
        """Star a user; returns the qualified name. Call `baseline()` to skip their history now."""
        user = qualify(user, home_domain)
        users = self.list()
        if user not in users:
            atomic_write(self.stars_file, format_stars(users + [user], self._header()))
        return user

    def remove(self, user: str, home_domain: str | None = None) -> bool:
        user = qualify(user, home_domain)
        users = self.list()
        if user not in users:
            return False
        atomic_write(self.stars_file, format_stars([u for u in users if u != user], self._header()))
        state = self._state()
        if state.pop(user, None) is not None:
            atomic_write(self.state_file, format_state(state))
        return True

    # -- read state ------------------------------------------------------------
    def _state(self) -> dict[str, int]:
        if not self.state_file.is_file():
            return {}
        return parse_state(self.state_file.read_text(encoding="utf-8"))

    def last_seen(self, user: str) -> int | None:
        return self._state().get(user.lower())

    def mark_seen(self, user: str, post_id: int) -> None:
        """Record that `user`'s posts up to `post_id` are read (never moves backwards)."""
        user = user.lower()
        state = self._state()
        if post_id > state.get(user, -1):
            state[user] = post_id
            atomic_write(self.state_file, format_state(state))

    def mark_all_seen(self, posts: list[Post]) -> None:
        state = self._state()
        changed = False
        for p in posts:
            user = self._author(p)
            if user and p.id > state.get(user, -1):
                state[user] = p.id
                changed = True
        if changed:
            atomic_write(self.state_file, format_state(state))

    # -- fetching --------------------------------------------------------------
    @staticmethod
    def _client(client: "Lemmy | LemmyClient") -> "LemmyClient":
        return getattr(client, "client", client)  # accept Lemmy or LemmyClient

    async def home_domain(self, client: "Lemmy | LemmyClient") -> str | None:
        c = self._client(client)
        await c.detect()
        if c.site is None:
            c.site = await c.call("site.get")
        return home_domain_of(c.site)

    @staticmethod
    def _author(post: Post) -> str | None:
        p = post.creator
        if p is None:
            return None
        host = urlparse(p.ap_id).hostname if p.ap_id else None
        return f"{p.name}@{host}".lower() if host else None

    async def _fetch(self, c: "LemmyClient", user: str, since: int | None, limit: int | None) -> list[Post]:
        """Posts by `user` newer than `since` (newest first), stopping once `since` is reached."""
        out: list[Post] = []
        cursor: str | None = None
        for page in range(1, MAX_PAGES + 1):
            if c.version == "v4":
                params: dict[str, Any] = {"creator_username": user, "sort": "new", "type_": "all", "limit": PAGE_SIZE}
                if page > 1:
                    if not cursor:
                        break
                    params["page_cursor"] = cursor
                data = await c.call("post.list", **params)
                cursor = data.get("next_page")
                raw = data.get("items") or []
            else:
                data = await c.call("person.get", username=user, sort="new", limit=PAGE_SIZE, page=page)
                raw = data.get("posts") or []
            posts = [Post.parse(c.version, r) for r in raw]
            done = not posts or len(posts) < PAGE_SIZE
            for p in posts:
                if since is not None and p.id <= since:
                    done = True
                    break
                out.append(p)
            if since is None or done or (limit and len(out) >= limit):
                break
        return out

    async def _per_user(self, client: "Lemmy | LemmyClient", users: list[str], peek: bool,
                        limit: int | None) -> dict[str, list[Post]]:
        c = self._client(client)
        await c.detect()
        state = self._state()
        sem = asyncio.Semaphore(CONCURRENCY)
        self.warnings = []
        baselines: dict[str, int] = {}

        async def one(user: str) -> tuple[str, list[Post]]:
            async with sem:
                since = state.get(user)
                try:
                    posts = await self._fetch(c, user, since, limit if since is not None else 1)
                except ApiError as e:
                    msg = f"stargaze: skipping {user}: {e.error}"
                    log.warning(msg)
                    self.warnings.append(msg)
                    return user, []
                if since is None:  # new star: start from their newest post
                    baselines[user] = posts[0].id if posts else 0
                    return user, []
                return user, posts

        results = dict(await asyncio.gather(*(one(u) for u in users)))
        if baselines and not peek:
            state = self._state()
            for user, seen in baselines.items():
                state.setdefault(user, seen)
            atomic_write(self.state_file, format_state(state))
        return results

    async def baseline(self, client: "Lemmy | LemmyClient", user: str) -> int:
        """Set a newly starred user's last_seen to their newest post (0 if none)."""
        await self._per_user(client, [user.lower()], peek=False, limit=1)
        return self.last_seen(user) or 0

    async def unread_counts(self, client: "Lemmy | LemmyClient") -> dict[str, int]:
        results = await self._per_user(client, self.list(), peek=False, limit=None)
        return {u: len(posts) for u, posts in results.items()}

    async def stargaze(self, client: "Lemmy | LemmyClient", peek: bool = False, user: str | None = None,
                       limit: int | None = None) -> list[Post]:
        """Unread posts from favorites, oldest first.

        peek=True doesn't record baselines for newly starred users. Reading
        never marks posts seen; call `mark_seen` (or `mark_all_seen`).
        """
        users = [user.lower()] if user else self.list()
        results = await self._per_user(client, users, peek=peek, limit=limit)
        posts = sorted((p for ps in results.values() for p in ps), key=lambda p: p.id)
        return posts[:limit] if limit else posts

    async def recent(self, client: "Lemmy | LemmyClient", user: str | None = None, per_user: int = 10) -> list[Post]:
        """Each favorite's latest posts, read or not, oldest first (doesn't touch the read state)."""
        c = self._client(client)
        await c.detect()
        users = [user.lower()] if user else self.list()
        sem = asyncio.Semaphore(CONCURRENCY)
        self.warnings = []

        async def one(u: str) -> list[Post]:
            async with sem:
                try:
                    return (await self._fetch(c, u, None, per_user))[:per_user]
                except ApiError as e:
                    self.warnings.append(f"stargaze: skipping {u}: {e.error}")
                    return []

        posts = [p for ps in await asyncio.gather(*(one(u) for u in users)) for p in ps]
        return sorted(posts, key=lambda p: p.id)

    def is_seen(self, post: Post) -> bool:
        user = self._author(post)
        seen = self.last_seen(user) if user else None
        return seen is not None and post.id <= seen

    def author_of(self, post: Post) -> str | None:
        """The qualified name that `post` would be filed under."""
        return self._author(post)


__all__ = ["Stars", "qualify", "parse_stars", "format_stars", "stars_header", "parse_state", "format_state", "home_domain_of"]

