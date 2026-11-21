"""luti: a Lemmy client library (API v3 for 0.19, v4 for 1.0) and terminal app.

Core (needs only httpx):
    LemmyClient   spec-driven async HTTP client: call(op, **params), pager(), paginate()
    Lemmy         higher-level async operations returning models
    SyncClient    blocking wrapper of Lemmy for scripts
    luti.models   Post, Comment, Person, Community, Report, Notification, ...
    luti.errors   LutiError and subclasses
    luti.config   opt-in helper for the profile files shared with luti's Bash CLI
    luti.urls     web URLs for posts, comments and media
    luti.stars    "stargaze": client-side favorite users

The terminal app lives in luti.tui (pip install "luti[tui]").
Importing luti has no side effects: no I/O, no config reads, no output.
"""

__version__ = "1.0.0"

import logging as _logging

_logging.getLogger("luti").addHandler(_logging.NullHandler())

from .api import Lemmy, ModelPager  # noqa: E402
from .client import LemmyClient, Pager  # noqa: E402
from .errors import (  # noqa: E402
    ApiError,
    AuthError,
    ConnectionFailed,
    LutiError,
    MfaRequired,
    NotFound,
    PermissionDenied,
    RateLimited,
    UnsupportedOperation,
    VersionDetectError,
)
from .models import (  # noqa: E402
    Comment,
    Community,
    Me,
    ModlogEntry,
    Notification,
    Person,
    Post,
    PrivateMessage,
    RegistrationApplication,
    Report,
    UnreadCounts,
)
from .sync import SyncClient  # noqa: E402

__all__ = [
    "__version__",
    "LemmyClient", "Lemmy", "SyncClient", "Pager", "ModelPager",
    "LutiError", "ConnectionFailed", "VersionDetectError", "UnsupportedOperation", "ApiError",
    "AuthError", "MfaRequired", "NotFound", "PermissionDenied", "RateLimited",
    "Post", "Comment", "Person", "Community", "Report", "Notification", "PrivateMessage",
    "RegistrationApplication", "ModlogEntry", "Me", "UnreadCounts",
]
