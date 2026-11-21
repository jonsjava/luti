"""luti's Textual terminal app (installed with: pip install "luti[tui]")."""
from __future__ import annotations

import sys

INSTALL_HINT = 'luti-tui needs the TUI extra: pip install "luti[tui]"'


def main(argv: list[str] | None = None) -> int:
    """Console entry point. Works without Textual installed (prints how to get it)."""
    try:
        import textual  # noqa: F401
    except ImportError:
        print(INSTALL_HINT, file=sys.stderr)
        return 2
    from .app import main as app_main

    return app_main(argv)
