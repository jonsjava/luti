# luti (Python)

A [Lemmy](https://join-lemmy.org/) client library and a terminal UI. It works
with Lemmy 0.19 (API v3) and 1.0 (API v4) and picks the right API
automatically. The API differences come from luti's shared endpoint map,
`spec/endpoints.json`, which is bundled into the package.

You can use it in two ways:

- **as an app:** `luti-tui`, a [Textual](https://textual.textualize.io/) client;
- **as a dependency:** `import luti` gives you an async client, a blocking
  client and typed models. The library needs only `httpx`.

## Install

```bash
pip install ./python              # library only (depends on httpx)
pip install './python[tui]'       # + the luti-tui app (textual, textual-image, pillow)
pip install './python[keyring]'   # + store login tokens in the system keyring
pip install './python[all]'       # everything
```

Running `luti-tui` without the `tui` extra prints the install command and exits with status 2.

## Library

### Async

```python
import asyncio
from luti import Lemmy, LemmyClient

async def main():
    async with Lemmy(LemmyClient("https://lemmy.example")) as lemmy:
        await lemmy.login("alice", "secret")          # the token stays in lemmy.client.token
        posts = await lemmy.posts(sort="new", limit=5).next_page()
        for post in posts:
            print(post.score, post.title, post.media_kind)
        post = await lemmy.vote_post(posts[0].id, "up")   # "up" / "down" / "clear"
        print(post.my_vote, await lemmy.unread())

asyncio.run(main())
```

`LemmyClient(instance, token=None, api=None, http_client=None)` works on its
own:

- `api="v3"` or `api="v4"` skips version detection.
- `http_client` lets you pass in your own `httpx.AsyncClient`. luti never
  closes a client you pass in.
- `await client.call("post.list", sort="new")` calls any op in the spec and
  returns the raw JSON.
- `client.paginate(op, ...)` iterates over v3 pages and v4 cursors alike.

`Lemmy` wraps the client with typed methods: posts, comments, inbox,
communities, people, search, reports, modlog, registrations, bans and purge.

### Blocking

```python
from luti import SyncClient

with SyncClient("https://lemmy.example") as lemmy:
    lemmy.login("alice", "secret")
    for post in lemmy.posts(sort="new", limit=5).next_page():
        print(post.id, post.title)
    lemmy.vote_post(post.id, "up")
```

`SyncClient` exposes every `Lemmy` method as a blocking call, using a private
event loop. Don't use it inside a running event loop; use `Lemmy` there.

### Models

`Post`, `Comment`, `Person`, `Community`, `PrivateMessage`, `Notification`,
`Report`, `RegistrationApplication`, `ModlogEntry`, `Me` and `UnreadCounts`
look the same on v3 and v4:

- Votes are `"up"`, `"down"` or `None`.
- Counts are plain ints.
- Each model's `.raw` holds the server's original JSON.
- Posts also carry `url`, `url_content_type`, `thumbnail_url`,
  `embed_video_url`, `alt_text` and `media_kind` (`image` / `video` / `link`
  / `none`).

### Errors

All errors subclass `luti.LutiError`:

| Exception | When |
|---|---|
| `ConnectionFailed` | the instance can't be reached |
| `VersionDetectError` | it doesn't answer like Lemmy 0.19 or 1.0 |
| `UnsupportedOperation` | the op doesn't exist on this server's API version |
| `ApiError` | Lemmy returned an error; `.error` is Lemmy's code (e.g. `couldnt_find_post`), plus `.status` and `.op` |
| `AuthError` (an `ApiError`) | bad login or expired token; `MfaRequired` when a TOTP code is needed |
| `NotFound`, `PermissionDenied`, `RateLimited` | further `ApiError` subclasses |

An unknown op name raises `KeyError`, because that is a programming error.

### Other modules

All of these are free of side effects on import:

- **`luti.urls`**: `post_url`, `comment_url`, `link_url`, `media_url`,
  `origin_url`, `page_url`.
  - `open_in_browser(url)` opens only http(s) URLs. It refuses `file:`,
    `javascript:` and similar schemes.
  - `webbrowser` is imported only when you call it.
- **`luti.media`**:
  - `media_kind()` detects media from the content type, then the file
    extension.
  - `probe_kind()` makes a HEAD request.
  - `fetch_image()` downloads http(s) URLs only, with a 10 MB cap and
    timeouts.
- **`luti.stars`**: favorite users and the stargaze queue (see below).
- **`luti.config`**: opt-in access to the profiles shared with the Bash CLI.
- **`luti.spec.load()`**: the endpoint map. Set `LUTI_SPEC=/path/to/endpoints.json` to use another copy.

The package logs to `logging.getLogger("luti")` and never prints. It ships
`py.typed`, and `luti.__version__` gives the version.

## luti-tui

```bash
luti-tui                     # default profile, or the login screen
luti-tui --profile work
luti-tui --images off        # override the profile's images setting
```

Press `?` or F1 for help anywhere, and `ctrl+p` for the command palette.

| Keys | Action |
|---|---|
| `F` `T` `I` `C` `/` `U` `M` `O` `A` `P` | feed, stargaze, inbox, communities, search, my profile, mod queue, modlog, admin, switch profile |
| `j`/`k`, `enter`, `esc`/`q` | move, open, back |
| `u`/`d`, `s`, `r` | vote, save, reply |
| `o` | open the post's link (the source article) in the browser |
| `p` / `c` | open the post's / selected comment's page on your instance |
| `m` | open the media (url, then embedded video, then thumbnail) |
| `y` | copy the link that `o` opens |
| `i` | view the image full-screen |
| `*` | star or unstar the author (stargaze) |
| `v` | reveal a hidden NSFW image |

The browser keys work wherever a post or comment is selected: the feed, a
post, the inbox, search results, the mod queue and stargaze.

### Images

Images show inline in the post view, in Markdown bodies and in comments.
Feed thumbnails can be turned off.

- **Renderer.** Images are drawn with
  [textual-image](https://github.com/lnqs/textual-image). It uses the Kitty
  graphics protocol or Sixel when the terminal supports one, and falls back to
  Unicode half-blocks otherwise. It was chosen over rich-pixels because it is
  a Textual widget, works with Textual 8, and covers all three output modes.
  rich-pixels does half-blocks only, so it isn't needed.
- **Detection.** Lemmy's `url_content_type` comes first, then the file
  extension, then a HEAD request.
- **Downloads.**
  - Only http(s) URLs are fetched, with no auth header.
  - There is a 10 MB cap and timeouts.
  - Pillow decodes images with a decompression-bomb limit and downscales big
    ones.
  - Images are cached in memory and in a 64 MB disk cache under
    `$XDG_CACHE_HOME/luti/images`.
- **Videos.** A video shows its thumbnail with a "video" badge; `m` opens it
  in the browser. Playing video in the terminal is planned for 1.1.
- **NSFW.** NSFW media follows your account's `show_nsfw`/`blur_nsfw`
  settings. Hidden images can be revealed with `v`.

### Stargaze

Star users with `*` to follow their posts in a queue.

- A ★ marks starred users everywhere.
- `T` opens Stargaze, which lists unread posts from your favorites, oldest
  first:
  - `enter` opens a post and marks it seen.
  - `n` opens the next unread post.
  - `x` marks everything seen.
  - `a` also shows posts you've already seen.
- `tab` moves to the favorites list, which shows each user's unread count.
  There, `enter` filters to that user and `*` unstars them.
- The unread count in the header refreshes in the background (every
  `stargaze_refresh` seconds).
- A newly starred user's queue starts after their newest post.

## Files (shared with the Bash CLI)

The same paths are used on every OS. `$XDG_CONFIG_HOME` defaults to
`~/.config`, and `$XDG_STATE_HOME` to `~/.local/state`.

| File | Contents |
|---|---|
| `$XDG_CONFIG_HOME/luti/<profile>/config` | `key=value` lines (values may be double-quoted): `instance`, `username`, `mfa` (true/false), optional `api` (v3/v4), and the settings below |
| `$XDG_CONFIG_HOME/luti/<profile>/token` | the raw JWT, mode 0600 in a 0700 directory; the password is never stored (with the `keyring` extra the token goes to the keyring; `LUTI_NO_KEYRING=1` keeps the file) |
| `$XDG_CONFIG_HOME/luti/<profile>/stars` | one `name@instance.host` per line, lowercase, sorted and unique; `#` comments and blank lines are allowed |
| `$XDG_STATE_HOME/luti/<profile>/stargaze` | `name@instance.host<TAB>last_seen_post_id` per line |

Writes are atomic: luti writes a temp file, then renames it over the old one.
The `instance.host` in a star is the user's federation domain, taken from the
instance's `ap_id`, not the URL you connect to.

Settings, as extra lines in the profile's `config` file:

| Key | Default | Meaning |
|---|---|---|
| `images` | `auto` | `auto` / `on` / `off`; `auto` shows feed thumbnails only with Kitty or Sixel graphics |
| `thumbnails` | `true` | thumbnails in the feed |
| `open_origin` | `false` | `p`/`c` open the federated original (`ap_id`) instead of your instance's page |
| `stargaze_refresh` | `300` | seconds between background stargaze checks (`0` turns it off) |

`LUTI_PROFILE` picks the default profile.

## Development

```bash
cd python
python3 -m venv .venv && .venv/bin/pip install -e '.[all,test]'
docker compose -f ../dev/docker-compose.yml up -d && ../dev/seed.sh
.venv/bin/pytest                          # everything; integration tests skip when the servers are down
.venv/bin/pytest -m 'not integration and not install'   # fast unit tests
```

The `install` tests build fresh virtualenvs and `pip install` the package, so they need the package index.
