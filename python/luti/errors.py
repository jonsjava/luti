"""luti's exception hierarchy.

    LutiError
    ├── ConnectionFailed          the instance could not be reached
    ├── VersionDetectError        not a Lemmy 0.19+ server
    ├── UnsupportedOperation      the op is null for the detected API version
    └── ApiError                  HTTP failure or a Lemmy {"error": ...} body (.error = Lemmy code)
        ├── AuthError             not logged in / bad credentials / expired token
        │   └── MfaRequired       a TOTP code is needed
        ├── PermissionDenied      not a moderator / admin
        ├── NotFound              no such object
        └── RateLimited           the server's rate limit was hit
"""
from __future__ import annotations


class LutiError(Exception):
    """Base class for every luti error."""


class ConnectionFailed(LutiError):
    """The instance could not be reached."""


class VersionDetectError(LutiError):
    """Neither /api/v4/site nor /api/v3/site answered like Lemmy."""


class UnsupportedOperation(LutiError):
    """The op has no route on the detected API version."""

    def __init__(self, op: str, version: str):
        super().__init__(f"{op} is not available on Lemmy API {version}")
        self.op = op
        self.version = version


UnsupportedOp = UnsupportedOperation  # short alias


class ApiError(LutiError):
    """HTTP failure or a Lemmy {"error": ...} body.

    Attributes: op (luti op name), status (HTTP status), error (Lemmy error
    code such as "not_a_moderator"), message (server detail, if any).
    """

    def __init__(self, op: str, status: int, error: str, message: str | None = None):
        self.op = op
        self.status = status
        self.error = error
        self.message = message
        detail = f"{error}: {message}" if message and message != error else error
        super().__init__(f"{op} failed (HTTP {status}): {detail}")


class AuthError(ApiError):
    """Not logged in, bad credentials or an expired token."""


class MfaRequired(AuthError):
    """The account needs a TOTP code (missing_totp_token / incorrect_totp_token)."""


class NotFound(ApiError):
    """The object does not exist (or was purged)."""


class PermissionDenied(ApiError):
    """The account lacks moderator or admin rights for this action."""


class RateLimited(ApiError):
    """The server's rate limit was hit."""


_AUTH_CODES = {"not_logged_in", "incorrect_login", "invalid_auth_token", "token_not_found"}
_MFA_CODES = {"missing_totp_token", "incorrect_totp_token"}
_PERM_CODES = {"not_a_moderator", "not_an_admin", "not_higher_mod", "not_higher_admin", "no_admins"}


def error_for(op: str, status: int, error: str, message: str | None) -> ApiError:
    """Build the most specific ApiError subclass for a failed call."""
    if error in _MFA_CODES:
        cls: type[ApiError] = MfaRequired
    elif error in _AUTH_CODES or status == 401:
        cls = AuthError
    elif error in _PERM_CODES or status == 403:
        cls = PermissionDenied
    elif error == "rate_limit_error" or status == 429:
        cls = RateLimited
    elif status == 404 or error.endswith("not_found") or error.startswith("couldnt_find"):
        cls = NotFound
    else:
        cls = ApiError
    return cls(op, status, error, message)


__all__ = [
    "LutiError", "ConnectionFailed", "VersionDetectError", "UnsupportedOperation", "UnsupportedOp",
    "ApiError", "AuthError", "MfaRequired", "NotFound", "PermissionDenied", "RateLimited", "error_for",
]
