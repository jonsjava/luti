# luti-tui

A terminal client for [Lemmy](https://join-lemmy.org/), built with
[Textual](https://textual.textualize.io/). It works with Lemmy 0.19 (API v3)
and 1.0 (API v4) and picks the right API automatically.

```bash
pip install ./python            # from a luti checkout
pip install './python[keyring]' # store the token in the system keyring
luti-tui                        # or: luti-tui --profile work
```

## Features

- Profiles shared with luti's Bash CLI (`~/.config/luti/<profile>/`)
- Feed with sort, top time range, listing type and community filters
- Posts with a collapsible comment tree; voting, saving and replying
- Compose posts, comments and private messages with a Markdown preview
- Inbox (replies, mentions and messages on 0.19; notifications on 1.0)
- Community browser, user profiles and search
- Mod queue: resolve reports, remove content, ban from the community
- Modlog, and an admin screen for registrations, site bans and purges

Press `?` anywhere for the key bindings. Keys are vim-style: `j`/`k` to
move, `enter` to open, `esc`/`q` to go back, `u`/`d` to vote, `r` to reply,
`s` to save.

## Configuration

Each profile is a directory `$XDG_CONFIG_HOME/luti/<profile>/` (default
`~/.config/luti/<profile>/`) on every OS:

- `config`: `key=value` lines with `instance`, `username`, `mfa` (true/false)
  and an optional `api` (`v3` or `v4`) to skip version detection.
- `token`: the login token (mode 0600). The password is never stored. With the
  `keyring` extra installed, the token goes to the keyring instead; set
  `LUTI_NO_KEYRING=1` to keep using the file.

`LUTI_PROFILE` picks the default profile; `LUTI_SPEC` points at another copy
of the endpoint map (`spec/endpoints.json`, bundled into the package).

## Development

```bash
cd python
python3 -m venv .venv && .venv/bin/pip install -e '.[test]'
docker compose -f ../dev/docker-compose.yml up -d && ../dev/seed.sh
.venv/bin/pytest            # unit + integration (integration skips if the servers are down)
.venv/bin/pytest -m 'not integration'
```
