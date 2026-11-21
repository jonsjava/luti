"""Web URLs for luti models. Pure functions: they return strings or None and launch nothing.

`open_in_browser` is the one helper with a side effect; the client never imports it.
"""
from __future__ import annotations

import logging
from typing import Any

from .media import is_web_url
from .models import Comment, Community, Person, Post

log = logging.getLogger("luti")


def _base(instance: str) -> str:
    instance = instance.strip().rstrip("/")
    return instance if "://" in instance else f"https://{instance}"


def post_url(post: Post, instance: str) -> str:
    """The post's page on `instance` (the user's home instance)."""
    return f"{_base(instance)}/post/{post.id}"


def comment_url(comment: Comment, instance: str) -> str:
    """The comment's page on `instance`."""
    return f"{_base(instance)}/comment/{comment.id}"


def person_url(person: Person, instance: str) -> str:
    return f"{_base(instance)}/u/{person.handle}"


def community_url(community: Community, instance: str) -> str:
    return f"{_base(instance)}/c/{community.handle.lstrip('!')}"


def link_url(post: Post) -> str | None:
    """The source article the post links to, if it is an http(s) link."""
    return post.url if is_web_url(post.url) else None


def media_url(post: Post) -> str | None:
    """Best URL for the post's media: an image/video link, then the embedded video, then the thumbnail."""
    if post.media_kind in ("image", "video") and is_web_url(post.url):
        return post.url
    for candidate in (post.embed_video_url, post.thumbnail_url):
        if is_web_url(candidate):
            return candidate
    return None


def origin_url(obj: Any) -> str | None:
    """The original federated copy (ap_id) of a post, comment, person or community."""
    ap_id = getattr(obj, "ap_id", None)
    return ap_id if is_web_url(ap_id) else None


def page_url(obj: Any, instance: str, prefer_origin: bool = False) -> str | None:
    """Home-instance page for a post/comment/person/community, or its ap_id if `prefer_origin`."""
    if prefer_origin:
        origin = origin_url(obj)
        if origin:
            return origin
    if isinstance(obj, Post):
        return post_url(obj, instance)
    if isinstance(obj, Comment):
        return comment_url(obj, instance)
    if isinstance(obj, Person):
        return person_url(obj, instance)
    if isinstance(obj, Community):
        return community_url(obj, instance)
    return None


def open_in_browser(url: str | None) -> bool:
    """Open an http(s) URL in the default browser. Anything else (file:, javascript:, ...) is refused.

    Returns False when the URL was refused or no browser could be started.
    """
    if not is_web_url(url):
        log.warning("refusing to open non-http(s) URL: %r", url)
        return False
    import webbrowser

    try:
        return bool(webbrowser.open(url, new=2))  # type: ignore[arg-type]
    except webbrowser.Error as e:
        log.warning("could not open %s: %s", url, e)
        return False


__all__ = ["post_url", "comment_url", "person_url", "community_url", "link_url", "media_url",
           "origin_url", "page_url", "open_in_browser", "is_web_url"]
