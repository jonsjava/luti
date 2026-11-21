# Changelog

## 1.0.0 (unreleased)

luti has been rewritten from a 180-line report watcher into a full Lemmy client. It supports Lemmy 0.19 (API v3) and 1.0 (API v4), detects which one a server runs, and comes in two parts that can each be used as an app or as a library.

### Added

- **Bash CLI (`bash/luti`):**
  - Login and profiles.
  - Feeds, posts and comments (create, edit, delete, vote, save, report), inbox and private messages, communities, users and search.
  - Moderation (reports, remove and restore, lock, feature, community bans, modlog) and administration (registrations, site bans, purges).
  - Output as tables, `--json` (raw) or `--norm` (normalized).
- **Bash library (`bash/lib/luti.sh`):** load it with `source` for use in scripts. It has `luti_*` functions and `LUTI_*` variables, and loading it has no side effects on the calling shell. Every result comes back as JSON in the same shape on both API versions. It can be installed with `make -C bash install` or basher.
- **Python library (`import luti`):** async and blocking clients, typed models in the same shape on both API versions (each keeps the raw response), typed errors and pagination helpers. It depends only on httpx.
- **Python TUI (`luti-tui`, installed with the `luti[tui]` extra):** a Textual app covering feeds, posts with comment trees, composing, inbox, communities, profiles, search, the mod queue, the modlog and admin screens, with vim-style keys.
- **Images in the TUI:** shown inline in posts and comments, with feed thumbnails, a full-screen viewer and NSFW hiding. Uses Kitty, Sixel or iTerm2 graphics where available and Unicode half-blocks elsewhere.
- **Stargaze (both tools):** star users and get a queue of their new posts. Favorites and read state are shared between the CLI and the TUI.
- **`luti watch`:** watch reports, registrations, the inbox, starred users, or all of them. New items ring the terminal bell, or optionally play a sound, send a desktop notification or run a hook command. `--once` suits cron.
- **Open in browser (both tools):** open the source article, the post or comment page, or the media. Only http(s) URLs are opened.
- **`spec/endpoints.json`:** a shared map of every operation to its API v3 and v4 routes, plus the differences between versions. Both libraries are driven by it.
- **`dev/`:** Docker Compose for local Lemmy 0.19.21 and 1.0.0-beta.3 servers, a seed script, and a route checker.
- Tests (bats and pytest) run against both server versions, and CI runs on GitHub Actions.

### Changed

- `luti.sh` is now a thin wrapper around `bash/luti watch reports` that still accepts its old flags. `-p/--password` still works but prints a warning; luti asks for the password instead.
- Login tokens are saved per profile (mode 0600), and the password is never stored. The config file is parsed rather than run with `source`.

### Fixed (from the 2024 script)

- Authentication now uses the `Authorization: Bearer` header. The `auth=` query parameter was removed in Lemmy 0.19.
- `-r` and `-f` are now parsed correctly.
- Passwords containing quotes no longer break login.

### Removed

- `functions` and the old root `config` file.
