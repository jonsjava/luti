# luti for Bash: the `luti` CLI and the luti library

This directory has two things:

- **`luti`**, a Lemmy client for the terminal. You can read, post, comment, moderate and administer with it. `luti watch` alerts you when reports, applications, messages or posts from your favorite users arrive.
- **The luti library** (`lib/luti.sh`). It is a set of Bash functions behind the CLI. Your own scripts can source it to talk to Lemmy without parsing API JSON themselves.

Both work with **Lemmy 0.19 (API v3)** and **Lemmy 1.0 (API v4)**. The server version is detected automatically. Results come back in one shape for both versions, so scripts don't need to know which version a server runs.

Contents:

1. [Requirements](#requirements)
2. [Installing](#installing)
3. [Using the CLI](#using-the-cli)
   - [Logging in and profiles](#logging-in-and-profiles)
   - [Reading](#reading)
   - [Writing](#writing)
   - [Inbox and private messages](#inbox-and-private-messages)
   - [Opening things in the browser](#opening-things-in-the-browser)
   - [Stars and stargaze: following users](#stars-and-stargaze-following-users)
   - [Moderation](#moderation)
   - [Administration](#administration)
   - [watch: alerts for new items](#watch-alerts-for-new-items)
   - [Output for scripts: --json and --norm](#output-for-scripts---json-and---norm)
   - [Files luti keeps](#files-luti-keeps)
   - [Exit codes](#cli-exit-codes)
   - [luti.sh (the old script)](#lutish-the-old-script)
4. [Using the library](#using-the-library)
   - [Loading it](#loading-it)
   - [A first script](#a-first-script)
   - [Conventions](#conventions)
   - [Variables](#variables)
   - [Common shapes](#common-shapes)
   - [Function reference](#function-reference)
5. [Development and tests](#development-and-tests)

---

## Requirements

- bash 4.3 or newer. On macOS, install a current bash with Homebrew, because the system bash is 3.2.
- curl
- jq 1.6 or newer
- Optional, for `watch` alerts: `notify-send` (Linux) or `osascript` (macOS) for desktop notifications, and `pw-play`, `paplay`, `aplay` or `afplay` for sounds.
- Optional, for `open`: `xdg-open`, `open` (macOS), `wslview` (WSL), or a browser named in `$BROWSER`.

## Installing

Run it from the checkout without installing:

```bash
bash/luti --help
```

Or install it with make. `PREFIX` defaults to `/usr/local`, and `DESTDIR` is supported for packaging:

```bash
make -C bash install PREFIX="$HOME/.local"
```

```bash
make -C bash uninstall PREFIX="$HOME/.local"
```

This installs:

| Path | What |
|---|---|
| `$PREFIX/bin/luti` | the CLI |
| `$PREFIX/share/luti/lib/` | the library; scripts source `lib/luti.sh` |
| `$PREFIX/share/luti/cli/` | modules used only by the CLI |
| `$PREFIX/share/luti/spec/endpoints.json` | the map of API v3/v4 endpoints the library follows |

`bin/luti` can be symlinked anywhere. It finds its files through `$LUTI_HOME` if that is set, then next to itself (the repository layout), then in `../share/luti` (the installed layout).

---

## Using the CLI

```
luti [GLOBAL OPTIONS] COMMAND [ARGS]
luti COMMAND --help        # every command and subcommand has its own help
```

Global options can go before or after the command:

| Option | Meaning |
|---|---|
| `--profile NAME` | use profile NAME (default `default`, or `$LUTI_PROFILE`) |
| `--instance URL` | use this instance instead of the profile's |
| `--api v3\|v4` | skip version detection |
| `--json` | print the raw API response |
| `--norm` | print luti's normalized JSON (the same on v3 and v4) |
| `-y`, `--yes` | don't ask for confirmation |
| `--version` | print luti's version |

### Logging in and profiles

```bash
luti login --instance lemmy.world --username alice
```

luti asks for anything you didn't give, and reads the password without echoing it. If your account uses two-factor authentication, add `--mfa`. If the server says a TOTP code is needed, luti asks for one anyway. The password is sent only to the server and is **never stored**; luti saves only the login token it gets back. In scripts, pipe the password, and then the TOTP code, on stdin, one per line:

```bash
printf '%s\n' "$PASSWORD" | luti login --instance https://lemmy.example --username bot
```

```bash
luti whoami        # name, admin flag, communities you moderate, instance, API version
luti logout        # invalidates the token on the server and deletes it locally
```

A **profile** is one saved login. Use several to switch between accounts or instances:

```bash
luti --profile work login --instance https://lemmy.example.org --username alice_mod
luti --profile work mod reports
export LUTI_PROFILE=work      # make it the default for this shell
```

Profile names may contain letters, digits, `.`, `_` and `-`.

### Reading

```bash
luti feed                                   # your front page (hot)
luti feed --sort new --community linux      # one community, newest first
luti feed --sort top --time week --type local
luti feed --saved                           # posts you saved
luti post view 123                          # a post and its comment tree
luti post view 123 --comments 200 --sort top
luti search "rust async" --type posts
luti community list --type subscribed
luti community show linux                   # description, counts, moderators
luti user show alice@lemmy.world            # profile, recent posts and comments
```

Feed options:

- `--sort`: hot, active, new, old, top, most_comments, new_comments, controversial or scaled.
- `--time` (with `--sort top`): hour, six_hour, twelve_hour, day, week, month, three_months, six_months, nine_months, year or all.
- `--type`: all, local, subscribed or moderator_view.

Lists end with a hint for the next page. On a 0.19 server it looks like `next: --page 2`; on a 1.0 server it is `next: --cursor X`. Pass the hint back to get that page:

```bash
luti feed --community linux --cursor BU0KBxiIGgGjd-ZRCLvW
```

Posts that link to an image or a video are tagged `[image]` or `[video]` in the feed. `post view` shows the link, the tag, any embedded video and the image's alt text.

### Writing

```bash
luti post create --community linux --title "Hello" --body "First post"
luti post create --community pics --title "Sunset" --url https://example.com/sunset.jpg
luti post create --community linux --title "Long one" --body-file draft.md
luti post edit 123 --title "Hello (edited)"
luti post vote 123 up            # up, down or clear
luti post save 123               # --undo to unsave
luti post delete 123             # --undo to restore
luti post report 123 --reason "spam"

luti comment reply --post 123 --text "Nice post"
luti comment reply 456 --text "Replying to comment 456"
luti comment edit 457 --text-file reply.md
luti comment vote 457 up
luti comment delete 457

luti community follow linux      # --undo to unfollow
luti community block memes       # --undo to unblock
```

### Inbox and private messages

```bash
luti inbox               # replies, mentions and messages; unread ones are marked *
luti inbox --unread
luti notify read         # mark everything read
luti notify read 42      # mark one notification read (Lemmy 1.0 only)
luti pm send bob --text "hi"
luti pm list
```

On 0.19 servers the inbox combines replies, mentions and private messages. On 1.0 servers it lists notifications.

### Opening things in the browser

```bash
luti open post 123            # the post on your instance, where you can vote and reply
luti open post 123 --link     # the article the post links to
luti open post 123 --media    # the image or video (else the embedded video or thumbnail)
luti open post 123 --origin   # the original copy on the instance it was posted to
luti open comment 456
luti open post 123 --print    # print the URL instead of opening it
luti post view 123 -o         # show the post and open it
```

The browser is `$BROWSER` if set; it can be a `:`-separated list, and each entry may include arguments. Otherwise luti tries `xdg-open`, then `open` (macOS), then `wslview`, then `cmd.exe`. Only `http://` and `https://` URLs are ever opened. If no launcher is found, luti prints the URL and exits with 1.

### Stars and stargaze: following users

Lemmy lets you follow communities but not people. **Stars** fill that gap. You *star* the users whose posts you never want to miss, and luti keeps a reading queue of their new posts for you. Reading that queue is called **stargazing**.

All of this lives on your computer, in your profile. Nothing is sent to the server, and the users you star are not told. The files are shared with the luti TUI, so your stars and your place in the queue are the same in both.

**1. Star someone.**

```bash
luti star add alice                      # a local user
luti star add bob@lemmy.world carol      # several at once; name@instance for remote users
luti star add --backfill 5 dave          # also queue dave's 5 most recent posts
```

luti looks the user up and saves them as `name@instance`, e.g. `alice@lemmy.example`. A new star starts *at their newest post*: only posts they make after you starred them show up as unread. Use `--backfill N` to also queue their N latest posts.

**2. See who you starred and how much is waiting.**

```bash
luti star list
```
```
USER                     UNREAD  LAST_SEEN_POST
alice@lemmy.example      2       1834
bob@lemmy.world          0       977
```

**3. Read the queue.**

```bash
luti stargaze             # list unread posts, oldest first, and mark them seen
luti stargaze --peek      # list them without marking anything seen
luti stargaze next        # show the oldest unread post in full, then mark it seen
luti stargaze --user alice --limit 3
luti stargaze --all       # recent posts including ones you've seen, newest first
luti stargaze clear       # mark everything seen
```

`stargaze next` is the one-at-a-time way to read. Run it again for the next post. When the queue is empty it says so and exits with 1, so it works in a loop:

```bash
while luti stargaze next; do read -rp "Enter for the next post, Ctrl-C to stop "; done
```

**4. Get alerted when a starred user posts.**

```bash
luti watch stars --notify           # keep running; desktop notification for each new post
luti watch all                      # stars together with reports and inbox
luti watch stars --once && echo "new posts from your stars"    # for cron
```

`watch stars` only looks; it never marks posts seen. They stay in the queue until you stargaze them.

**5. Unstar.**

```bash
luti star remove alice          # a bare name works when it matches one star
luti star remove bob@lemmy.world
```

How it works: post ids on your instance only ever grow, so luti remembers, per starred user, the id of the last post of theirs you have seen. Unread posts are the ones with a higher id. If a starred user is renamed or deleted, stargaze prints a warning for them and carries on with the others. Both files are plain text, can be edited by hand, and are described under [Files luti keeps](#files-luti-keeps).

### Moderation

```bash
luti mod reports                         # open post, comment and message reports
luti mod reports --type comment --community linux --all   # --all includes resolved ones
luti mod resolve post 17                 # --undo to reopen
luti mod remove post 123 --reason "off topic"
luti mod restore post 123
luti mod remove comment 456 --reason "rule 2"
luti mod lock 123                        # --undo to unlock
luti mod feature 123                     # pin in the community; --local pins on the instance (admins)
luti mod ban troll --community linux --reason "spam" --days 7 --remove-data
luti mod unban troll --community linux
luti modlog --community linux --type mod_remove_post
```

### Administration

```bash
luti admin registrations                 # pending applications (--all includes decided ones)
luti admin approve newuser               # application id or username
luti admin deny spammer --reason "bot"
luti admin ban troll --reason "spam" --days 30
luti admin unban troll
luti admin purge post 123                # cannot be undone: asks first, or pass --yes
```

### watch: alerts for new items

`luti watch` keeps polling, shows a compact status screen, and alerts you when something new arrives:

```bash
luti watch                     # reports (the default), terminal bell on new ones
luti watch inbox --notify
luti watch all --refresh 30 --sound ~/sounds/ping.oga
luti watch reports --community linux --exec 'curl -s -d @- https://ntfy.sh/my-mod-queue'
```

| Kind | What is watched | Who |
|---|---|---|
| `reports` | open post, comment and private message reports | moderators |
| `registrations` | pending registration applications | admins |
| `inbox` | unread replies, mentions, messages and notifications | everyone |
| `stars` | new posts from your [starred users](#stars-and-stargaze-following-users) | everyone |
| `all` | all of the above (registrations only if you are an admin) | |

| Option | Meaning |
|---|---|
| `--refresh N` | seconds between polls (default 60, minimum 10) |
| `--community C` | only reports from community C |
| `--quiet` | no terminal bell |
| `--sound FILE` | play FILE with pw-play, paplay, aplay or afplay |
| `--notify` | desktop notification with notify-send or osascript |
| `--exec CMD` | run `bash -c CMD` once per new item, with the item's JSON on stdin |
| `--once` | poll once, compare with the last run, and exit (see below) |

New items are recognized by id, not by count. If one report is resolved while another arrives, the new one still alerts. The first poll only records what is already pending; you get one alert per poll, however many items arrived. When the network or the server fails, watch keeps retrying, doubling the wait up to 10 minutes. If the login expires, it stops with exit code 3. Ctrl-C quits and restores the cursor.

The item JSON that `--exec` receives is the normalized report, application, notification or post, plus `watch` (the kind) and `key` (e.g. `"post:12"`):

```bash
luti watch reports --exec 'jq -r "\(.type) report: \(.reason)" >> ~/reports.log'
```

`--once` is for cron and scripts. It compares with the state saved by the previous `--once` run and exits **0 if something is new**, 1 if nothing is new, 2 on an error, and 3 if the login expired:

```cron
*/5 * * * * luti watch reports --once --notify
```

### Output for scripts: --json and --norm

By default luti prints tables and text for people. For scripts:

- `--norm` prints luti's **normalized JSON**. It has the same fields on 0.19 and 1.0 servers; the shapes are listed in [Common shapes](#common-shapes). Lists are `{"items": [...], "next": ...}`.
- `--json` prints the **raw API response**, which differs between versions.

```bash
luti --norm feed --community linux --limit 50 | jq -r '.items[] | "\(.score)\t\(.title)"'
luti --norm mod reports | jq '.items | length'
```

### Files luti keeps

Per profile, under `${XDG_CONFIG_HOME:-~/.config}/luti/<profile>/` (directory mode 0700):

| File | Contents |
|---|---|
| `config` | `key="value"` lines: `instance`, `username`, `mfa` (true/false), optional `api` (v3/v4 to skip detection). Read line by line and never executed. |
| `token` | the login token (mode 0600) |
| `api_cache` | the detected API version for the instance |
| `stars` | starred users, one `name@instance` per line, sorted; blank lines and `#` comments allowed |

Under `${XDG_STATE_HOME:-~/.local/state}/luti/<profile>/`:

| File | Contents |
|---|---|
| `stargaze` | `name@instance<TAB>last_seen_post_id`, one line per starred user |
| `watch-<kind>` | ids that were pending at the last `watch --once` run |

The same files are used by the luti TUI, so a login, stars and the stargaze position carry over between the two. `stars` and `stargaze` are written atomically (via a temporary file and a rename).

### CLI exit codes

| Code | Meaning |
|---|---|
| 0 | success (`watch --once`: something new) |
| 1 | failure; or `watch --once` found nothing new; or `stargaze next` found an empty queue; or `open` found no launcher |
| 2 | `watch --once`: error |
| 3 | `watch`: login expired or rejected |

### luti.sh (the old script)

`luti.sh` in the repository root still works for existing setups. It is now a thin wrapper: it maps the old flags (`-i`, `-u`, `-f`, `-r`, …) onto `luti login` and `luti watch reports`. `-p PASSWORD` still works but warns, because it puts the password in the process list. Refresh intervals below 10 seconds are raised to 10.

---

## Using the library

### Loading it

Source **one file**, `lib/luti.sh`. It loads the rest of the library:

```bash
. /usr/local/share/luti/lib/luti.sh        # installed (PREFIX=/usr/local)
. "$HOME/.local/share/luti/lib/luti.sh"    # installed with PREFIX=~/.local
. /path/to/luti/bash/lib/luti.sh           # from a checkout
```

The library finds `spec/endpoints.json` relative to itself. Set `LUTI_SPEC=/path/to/endpoints.json` to use another copy.

Sourcing is safe in any script:

- It only defines functions named `luti_*` (public) and `_luti_*` (internal), and variables named `LUTI_*`.
- It runs nothing else: no requests, no config reads, no `exit`, no changes to `set` options, `IFS`, traps or the working directory.
- It works under `set -euo pipefail`.

It needs bash 4.3+, curl and jq. With an older bash, `source` returns 1 with a message.

### A first script

```bash
#!/usr/bin/env bash
set -euo pipefail
. /usr/local/share/luti/lib/luti.sh

luti_connect https://lemmy.example          # sets LUTI_INSTANCE and detects LUTI_API
LUTI_TOKEN=$(luti_login mybot "$BOT_PASSWORD")

# The 5 newest posts in !linux, as "id<TAB>title"
luti_post_list '{"community": "linux", "sort": "new", "limit": 5}' |
	jq -r '.items[] | "\(.id)\t\(.title)"'

# Upvote and reply to the first one
id=$(luti_post_list '{"community": "linux", "sort": "new", "limit": 1}' | jq '.items[0].id')
luti_post_vote "$id" up >/dev/null
luti_comment_create "$(jq -nc --argjson p "$id" '{post_id: $p, content: "Welcome!"}')" | jq .id
```

To reuse a login made with `luti login`, load the profile instead of logging in:

```bash
luti_config_load work      # sets LUTI_INSTANCE, LUTI_TOKEN, LUTI_API, ... from profile "work"
luti_whoami | jq -r .name
```

Paging through everything: pass `next` back until it is `null`. This works the same on v3 and v4:

```bash
next=null
while :; do
	page=$(luti_post_list "$(jq -nc --argjson n "$next" '{community: "linux", limit: 50, next: $n}')")
	jq -r '.items[].title' <<<"$page"
	next=$(jq '.next' <<<"$page")
	[[ $next != null ]] || break
done
```

A moderator bot that reacts to new reports:

```bash
state="$(luti_state_dir)/mybot-reports"
while sleep 60; do
	luti_watch_poll reports "$state" '{"community": "linux"}' |
		jq -c '.new[]' | while read -r r; do
			printf 'new %s report: %s\n' "$(jq -r .type <<<"$r")" "$(jq -r .reason <<<"$r")"
		done
done
```

### Conventions

- **Options are JSON.** Functions that take several options take one JSON object, e.g. `'{"sort": "top", "time": "week"}'`. Build it with `jq -n --arg` when values come from variables. Unknown keys are ignored; missing keys use the default.
- **Output is JSON on stdout**, in the [common shapes](#common-shapes). Lists are `{"items": [...], "next": ...}`. `next` is a page number on v3 and a cursor string on v4, and `null` on the last page. Pass it back as `{"next": ...}`.
- **Raw output:** set `LUTI_RAW=1`, for one call (`LUTI_RAW=1 luti_post_get 5`) or globally, to get the server's own JSON instead.
- **Errors** go to stderr as `luti: ...`, and the function returns non-zero:

| Code | Meaning |
|---|---|
| 1 | the request failed (server error, not found, unreachable, bad argument) |
| 2 | bad op or request (e.g. not available on this API version), or no instance set |
| 3 | `luti_login`: a TOTP code is required or was wrong |
| 4 | the token was rejected (expired or logged out): log in again |

- **`luti_connect` and `luti_config_load` must be called directly, not inside `$(...)`**, so the variables they set stay in your shell. If `LUTI_API` is empty, it is detected on the first request. Call `luti_connect` once first; otherwise each `$(...)` call detects it again.
- **Names** can be given where Lemmy wants ids: communities as `name`, `name@instance` or an id; users as `name`, `name@instance` or an id.
- The library never prints tables, asks questions, or reads the terminal. That is the CLI's job.

### Variables

| Variable | Meaning |
|---|---|
| `LUTI_INSTANCE` | base URL, e.g. `https://lemmy.world` |
| `LUTI_TOKEN` | login token (JWT); empty for anonymous requests |
| `LUTI_API` | `v3` or `v4`; empty means detect on first use |
| `LUTI_SPEC` | path to `endpoints.json`; empty means the one next to the library |
| `LUTI_TIMEOUT` | curl timeout in seconds (default 30) |
| `LUTI_RAW` | `1` makes data functions print raw API JSON |
| `LUTI_PROFILE` | profile used by config, stars and state functions (default `default`) |
| `LUTI_USERNAME`, `LUTI_MFA`, `LUTI_CONFIG_API` | set by `luti_config_load`; written by `luti_config_save` |
| `LUTI_LIB_DIR`, `LUTI_VERSION` | where the library is, and its version (read only) |

Values already in the environment when the library is sourced are kept.

### Common shapes

These are the fields of the normalized objects. Times are ISO 8601 strings. `creator`, `community`, `reporter` and the like are `{id, name}`. `my_vote` is `"up"`, `"down"` or `null`.

**post**

```
id, title, body, url, url_content_type, thumbnail_url, embed_video_url, alt_text,
media_kind ("image" | "video" | "link" | "none"), ap_id, community, creator,
score, upvotes, downvotes, comments, published, my_vote, saved, locked, removed,
deleted, featured
```

`media_kind` comes from the server's content type, falling back to the URL's file extension.

**comment**

```
id, ap_id, post_id, post_title, parent_id, depth, path, content, creator,
community, score, upvotes, downvotes, children, published, my_vote, saved,
removed, deleted
```

**person**

```
id, name, display_name, bio, published, posts, comments, is_admin, banned, bot
```

**community**

```
id, name, title, description, subscribers, posts, comments,
subscribed ("subscribed" | "not_subscribed" | "pending"), blocked, removed,
deleted, nsfw, published
```

**report**

```
id, type ("post" | "comment" | "private_message"), reason, resolved, published,
target_id, post_id, text, reporter, target_creator, community
```

**notification** (inbox items)

```
id, kind ("reply" | "mention" | "private_message" | ...), read, published, creator, text,
post_id, post_title, comment_id, private_message_id
```

**pm**

```
id, content, read, published, creator, recipient, deleted
```

**registration**

```
id, username, person_id, answer, published,
status ("pending" | "approved" | "denied"), deny_reason, admin
```

**modlog**

```
kind (e.g. "mod_remove_post"), published, reason, revert, moderator, target, target_text
```

**account** (`luti_whoami`)

```
id, name, display_name, admin, moderates (community names)
```

(`luti --norm whoami` also adds `instance`, `api` and `profile`.)

### Function reference

`OPTS` is a JSON object; `BOOL` is `true` or `false` (default `true`). Arguments in `[ ]` are optional.

#### Connection and raw API

| Function | Prints / does |
|---|---|
| `luti_connect [INSTANCE] [TOKEN] [API]` | sets `LUTI_INSTANCE`/`LUTI_TOKEN`/`LUTI_API`; detects the API if not given |
| `luti_detect_version [INSTANCE]` | `v4` or `v3` |
| `luti_normalize_instance URL` | adds `https://`, drops trailing `/` |
| `luti_api OP [JSON]` | calls any op in `spec/endpoints.json` (v4 field names; renamed for v3 automatically) and prints the raw response |
| `luti_api_has OP` | true if OP exists on the current API version |

`luti_api` is the escape hatch for anything without its own function:

```bash
luti_api site.get | jq -r '.site_view.site.name'
```

#### Login

| Function | Prints / does |
|---|---|
| `luti_login USER PASSWORD [TOTP]` | the token (returns 3 if a TOTP code is needed) |
| `luti_logout` | invalidates `LUTI_TOKEN` on the server |
| `luti_whoami` | account |

#### Profiles and config (opt-in)

| Function | Prints / does |
|---|---|
| `luti_config_load [PROFILE]` | sets all `LUTI_*` connection variables from the profile |
| `luti_config_save` | writes `LUTI_INSTANCE`, `LUTI_USERNAME`, `LUTI_MFA`, `LUTI_CONFIG_API` to the profile |
| `luti_token_save [TOKEN]` / `luti_token_delete` | stores (0600) or deletes the profile's token |
| `luti_config_cache_api` | remembers the detected `LUTI_API` for the instance |
| `luti_config_dir [PROFILE]` / `luti_state_dir [PROFILE]` | the profile's config and state directories |
| `luti_valid_profile NAME` | true for a valid profile name |

#### Posts

| Function | Prints |
|---|---|
| `luti_post_list [OPTS]` | `{items: [post], next}`. OPTS: `sort`, `time`, `type` (all, local, subscribed, moderator_view), `community`, `creator` (v4), `saved`, `limit` (20), `page` / `cursor` / `next` |
| `luti_post_get ID [OPTS]` | `{post, comments: [comment]}`. OPTS: `comments` (how many, default 50; 0 = none), `comment_sort` |
| `luti_post_create OPTS` | post. OPTS: `community`, `title`, `body`, `url`, `nsfw` |
| `luti_post_edit ID OPTS` | post. OPTS: `title`, `body`, `url` (only the given fields change) |
| `luti_post_delete ID [BOOL]` | post (`false` restores) |
| `luti_post_save ID [BOOL]` | post |
| `luti_post_vote ID up\|down\|clear` | post |
| `luti_post_report ID REASON` | the report |

#### Comments

| Function | Prints |
|---|---|
| `luti_comment_list POST_ID [OPTS]` | `{items: [comment], next}`. OPTS: `sort`, `limit` (50), `max_depth`, `page` / `cursor` / `next` |
| `luti_comment_get ID` | comment |
| `luti_comment_create OPTS` | comment. OPTS: `content`, `post_id` and/or `parent_id` |
| `luti_comment_edit ID CONTENT` | comment |
| `luti_comment_delete ID [BOOL]` | comment |
| `luti_comment_vote ID up\|down\|clear` | comment |
| `luti_comment_report ID REASON` | the report |

#### Communities, users, search

| Function | Prints |
|---|---|
| `luti_community_list [OPTS]` | `{items: [community], next}`. OPTS: `type`, `sort`, `limit`, `page` / `cursor` / `next` |
| `luti_community_get NAME\|ID` | `{community, moderators: [{id, name}]}` |
| `luti_community_follow NAME\|ID [BOOL]` | community |
| `luti_community_block NAME\|ID [BOOL]` | community |
| `luti_community_id NAME\|ID` / `luti_person_id NAME\|ID` | the numeric id |
| `luti_person_get NAME\|ID [OPTS]` | `{person, posts, comments}`. OPTS: `limit` (10), `sort` |
| `luti_search QUERY [OPTS]` | `{posts, comments, communities, users, next}`. OPTS: `type`, `community`, `sort`, `limit`, `page` / `cursor` / `next` |

#### Inbox and private messages

| Function | Prints |
|---|---|
| `luti_inbox [OPTS]` | `{items: [notification], next}`, newest first. OPTS: `unread`, `limit`, `page` / `cursor` / `next` |
| `luti_notification_read ID [BOOL]` | marks one notification read (v4 only) |
| `luti_mark_all_read` | marks the inbox read |
| `luti_pm_send USER TEXT` | pm |
| `luti_pm_list [OPTS]` | `{items: [pm], next}` |

#### Moderation and administration

| Function | Prints |
|---|---|
| `luti_report_list [OPTS]` | `{items: [report]}`. OPTS: `type` (post, comment, pm, all), `all` (include resolved), `community`, `limit` |
| `luti_report_resolve post\|comment\|pm ID [BOOL]` | report |
| `luti_post_remove ID [BOOL] [REASON]` / `luti_comment_remove ...` | post / comment (`false` restores) |
| `luti_post_lock ID [BOOL]` | post |
| `luti_post_feature ID [BOOL] [community\|local]` | post |
| `luti_community_ban USER COMMUNITY [BOOL] [OPTS]` | `{person, community_id, banned}`. OPTS: `reason`, `days`, `remove_data` |
| `luti_ban USER [BOOL] [OPTS]` | site ban: `{person, banned}` |
| `luti_modlog [OPTS]` | `{items: [modlog], next}`. OPTS: `community`, `user`, `type`, `limit` |
| `luti_registration_list [OPTS]` | `{items: [registration]}`. OPTS: `all`, `limit` |
| `luti_registration_decide ID\|USERNAME BOOL [REASON]` | registration (`true` approves) |
| `luti_registration_id ID\|USERNAME` | the application id |
| `luti_purge person\|community\|post\|comment ID\|NAME [REASON]` | `{kind, id, purged}`. **Cannot be undone.** |
| `luti_counts` | `{reports, post_reports, comment_reports, private_message_reports, registrations, notifications}` (fields a version lacks are `null`) |

#### Watching for new items

| Function | Prints |
|---|---|
| `luti_watch_poll KIND STATEFILE [OPTS]` | `{kind, baseline, new: [...], pending, items: [...]}`. KIND: `reports`, `registrations`, `inbox`, `stars`. OPTS: `community` (reports). STATEFILE is created and updated; the first poll is a baseline with `new: []`. |
| `luti_watch_diff STATEFILE` | the same comparison for your own items: reads a JSON array of objects with a `key` field on stdin |

#### Stars and stargaze

These use the profile's `stars` and `stargaze` files ([format](#files-luti-keeps)), so they work together with the CLI and the TUI.

| Function | Prints / does |
|---|---|
| `luti_stars_list` | `[{user, last_seen}]` |
| `luti_stars_add [--backfill N] USER...` | `[{user, last_seen}]` for the users starred (unknown users: message, return 1) |
| `luti_stars_remove USER...` | the removed names, as a JSON array |
| `luti_stars_qualify USER` | `name@instance` for USER |
| `luti_stargaze_poll [--peek] [--all] [--user U] [--limit N]` | `{items: [post + {star}]}`, oldest first, marked seen unless `--peek` |
| `luti_stargaze_mark USER POST_ID` | marks USER's posts up to POST_ID as seen (never moves back) |
| `luti_stargaze_clear` | marks everything seen |

#### URLs and the browser

| Function | Prints / does |
|---|---|
| `luti_url post\|comment ID [page\|link\|media\|origin]` | a URL; launches nothing (`page` needs no request) |
| `luti_safe_url URL` | true for an `http(s)://` URL without spaces or control characters |
| `luti_open_url URL` | opens URL in the browser, detached. Returns 1 (and prints the URL) if there is no launcher, 2 if the URL is refused |

---

## Development and tests

Install the test tools locally (nothing system-wide):

```bash
cd tests/bash/.tools && npm i bats && python3 -m venv venv && venv/bin/pip install shellcheck-py
```

Run the checks:

```bash
make -C bash check     # shellcheck
```

```bash
make -C bash test      # all bats tests
```

The unit tests (`tests/bash/unit_*.bats`) use a stub curl and responses captured from real servers. The integration tests (`integration_v3.bats` and `integration_v4.bats`) run every command against the dev servers, so start those first:

```bash
docker compose -f dev/docker-compose.yml up -d && dev/seed.sh
```

The integration tests are skipped when the servers are unreachable, unless `LUTI_REQUIRE_SERVERS=1` is set.

Layout:

| Path | What |
|---|---|
| `luti` | the CLI entry point: argument parsing and dispatch |
| `cli/` | CLI commands, prompts, and `display.jq` (tables and text) |
| `lib/luti.sh` | the library entry point (sources the modules below) |
| `lib/api.sh` | version detection and `luti_api`, driven by `spec/endpoints.json` |
| `lib/luti.jq` | normalizers (v3/v4 → common shapes) and request builders |
| `lib/*.sh` | one module per area: auth, content, community, inbox, mod, open, watch, stars, config, util |
