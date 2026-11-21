# luti: Lemmy User Terminal Interface

luti is a terminal client for [Lemmy](https://join-lemmy.org/). You can read, post, comment and vote with it, and also moderate and administer an instance. It works with Lemmy **0.19** (API v3) and **1.0** (API v4) and detects which one a server runs.

It comes in two parts. Each one works on its own as an app, and each can be used as a library in your own code:

| | App | Library | Needs |
|---|---|---|---|
| **[Bash](bash/README.md)** | `luti`, a command-line client | `source bash/lib/luti.sh` in your scripts | bash 4+, curl, jq |
| **[Python](python/README.md)** | `luti-tui`, a full-screen terminal UI | `import luti` (async and blocking clients, typed models) | Python 3.10+; the library needs only httpx |

Both parts read the same profiles, so an account set up in one works in the other. Your starred users and their read state are shared the same way.

## Quick start

### Bash CLI

```bash
git clone https://github.com/jonsjava/luti && cd luti
```

```bash
bash/luti login --instance https://lemmy.example
```

```bash
bash/luti feed --sort top --time day
```

To install it, run `make -C bash install PREFIX="$HOME/.local"`, or `basher install jonsjava/luti`.

### Python TUI

```bash
pip install "luti[tui] @ git+https://github.com/jonsjava/luti#subdirectory=python"
```

```bash
luti-tui
```

Leave out `[tui]` to install only the library.

## What it does

- **Reading:** feeds with sort, time and listing filters; posts with comment trees; communities, user profiles and search.
- **Writing:** posts, comments, replies, votes, saves, reports and private messages.
- **Inbox:** replies, mentions and messages on 0.19; notifications on 1.0.
- **Moderation:** a report queue with resolve, remove, restore, lock, feature and community ban; the modlog.
- **Administration:** registration applications (approve and deny), site bans and purges.
- **Stargaze:** star the users you like and get a queue of their new posts. Lemmy can't follow people, so luti does it on the client side.
- **Watch** (CLI): `luti watch reports|registrations|inbox|stars|all` rings the terminal bell when something new arrives. It can also play a sound, send a desktop notification or run your own command. `--once` suits cron.
- **Open in browser:** open the source article, the post or comment page, or the media.
- **Images** (TUI): shown inline in posts and comments, with feed thumbnails. Uses Kitty, Sixel or iTerm2 graphics where the terminal supports them, and Unicode blocks everywhere else.

## Configuration

Profiles live in `${XDG_CONFIG_HOME:-~/.config}/luti/<profile>/`:

| File | What |
|---|---|
| `config` | `key=value` lines: `instance`, `username`, `mfa`, and optionally `api`, plus TUI settings such as `images` |
| `token` | the login token (mode 0600). The password is never stored. |
| `stars` | starred users, one `name@instance` per line |

Read state for stargaze and watch is kept in `${XDG_STATE_HOME:-~/.local/state}/luti/<profile>/`. Choose a profile with `--profile NAME` in either tool.

## How the two API versions are handled

[`spec/endpoints.json`](spec/endpoints.json) maps each luti operation (for example `post.list` or `report.list.post`) to its method and path on API v3 and v4. It also records the differences between versions: renamed fields, plural report filters, vote and pagination formats, enum case, and fields the server requires. Both libraries are driven by this file instead of hard-coding routes, so it's also a useful reference if you're writing a Lemmy client in another language.

## Development

The `dev/` folder runs two throwaway Lemmy servers in Docker for testing: 0.19.21 on port 8536 and 1.0.0-beta.3 on port 8537.

```bash
docker compose -f dev/docker-compose.yml up -d
```

```bash
dev/seed.sh
```

```bash
dev/check-spec.sh
```

`seed.sh` creates test users and content and can be rerun safely. `check-spec.sh` confirms that every route in the spec exists on both servers.

The tests run against both servers:

- **Bash:** set up the tools with `cd tests/bash/.tools && npm i bats && python3 -m venv venv && venv/bin/pip install shellcheck-py`, then run `make -C bash check test`.
- **Python:** `cd python && python3 -m venv .venv && .venv/bin/pip install -e '.[tui,test]' && .venv/bin/pytest`.

CI runs shellcheck, the unit tests and the integration tests on every push and pull request (see `.github/workflows/ci.yml`).

## Roadmap

- **1.1:** video playback in the TUI.

## License

MIT. See [LICENSE](LICENSE).
