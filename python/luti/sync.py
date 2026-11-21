"""A small synchronous wrapper for scripts.

    from luti import SyncClient
    with SyncClient("https://lemmy.example") as lemmy:
        lemmy.login("me", "password")
        for post in lemmy.posts(sort="hot").next_page():
            print(post.score, post.title)
        lemmy.vote_post(post.id, "up")

Every coroutine method of `luti.Lemmy` is available as a plain method. Each
SyncClient runs its own event loop, so don't use it inside a running loop
(use `Lemmy` / `LemmyClient` directly there).
"""
from __future__ import annotations

import asyncio
import functools
import inspect
from typing import Any

import httpx

from .api import Lemmy, ModelPager
from .client import LemmyClient


class SyncPager:
    """Blocking version of ModelPager."""

    def __init__(self, pager: ModelPager, runner: "SyncClient"):
        self._pager = pager
        self._runner = runner

    @property
    def has_more(self) -> bool:
        return self._pager.has_more

    def next_page(self) -> list:
        return self._runner._run(self._pager.next_page())

    def __iter__(self):
        while self.has_more:
            yield from self.next_page()


class SyncClient:
    """Blocking facade over `Lemmy`. Arguments are those of `LemmyClient`."""

    def __init__(self, instance: str, token: str | None = None, api: str | None = None,
                 http_client: httpx.AsyncClient | None = None, **kwargs: Any):
        self._loop = asyncio.new_event_loop()
        self.lemmy = Lemmy(LemmyClient(instance, token=token, api=api, http_client=http_client, **kwargs))

    @property
    def client(self) -> LemmyClient:
        return self.lemmy.client

    def _run(self, aw: Any) -> Any:
        return self._loop.run_until_complete(aw)

    def call(self, op: str, **params: Any) -> Any:
        """Raw spec op call (see LemmyClient.call)."""
        return self._run(self.client.call(op, **params))

    def paginate(self, op: str, limit: int = 20, max_items: int | None = None, **params: Any) -> list[dict]:
        async def collect() -> list[dict]:
            return [i async for i in self.client.paginate(op, limit, max_items, **params)]

        return self._run(collect())

    def __getattr__(self, name: str) -> Any:
        attr = getattr(self.lemmy, name)
        if inspect.iscoroutinefunction(attr):
            @functools.wraps(attr)
            def blocking(*args: Any, **kwargs: Any) -> Any:
                return self._run(attr(*args, **kwargs))
            return blocking
        if callable(attr):
            @functools.wraps(attr)
            def maybe_pager(*args: Any, **kwargs: Any) -> Any:
                result = attr(*args, **kwargs)
                return SyncPager(result, self) if isinstance(result, ModelPager) else result
            return maybe_pager
        return attr

    def close(self) -> None:
        if not self._loop.is_closed():
            self._run(self.lemmy.aclose())
            self._loop.close()

    def __enter__(self) -> "SyncClient":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()
