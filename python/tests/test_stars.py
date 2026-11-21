"""Favorite users (stars) and the stargaze queue."""
import pytest
from conftest import USER_PW, unique

from luti.api import Lemmy
from luti.client import LemmyClient
from luti.config import config_root, state_root
from luti.models import Person, Post
from luti.stars import Stars, format_state, home_domain_of, parse_stars, parse_state, qualify


def test_qualify():
    assert qualify("Alice", "Lemmy.Test") == "alice@lemmy.test"
    assert qualify("@bob@far.away", None) == "bob@far.away"
    for bad in ("", "  ", "a@", "@", "a b@c.d", "a@b@c"):
        with pytest.raises(ValueError):
            qualify(bad, "home.test")
    with pytest.raises(ValueError):
        qualify("alice", None)  # a bare name needs the home domain


def test_parse_stars_comments_blanks_duplicates():
    text = "# my favorites\n\nbob@b.test\nAlice@a.test   # the mod\n@alice@a.test\n  \n"
    assert parse_stars(text) == ["alice@a.test", "bob@b.test"]


def test_bash_state_file_round_trip():
    bash = "alice@a.test\t42\n# comment\n\nbob@b.test\t7\ncarol@c.test 3\nbroken line\n"
    state = parse_state(bash)
    assert state == {"alice@a.test": 42, "bob@b.test": 7, "carol@c.test": 3}
    out = format_state(state)
    assert out == "alice@a.test\t42\nbob@b.test\t7\ncarol@c.test\t3\n"
    assert parse_state(out) == state


def test_stars_files_and_paths():
    s = Stars("work")
    assert s.stars_file == config_root() / "work" / "stars"
    assert s.state_file == state_root() / "work" / "stargaze"
    assert s.list() == [] and s.last_seen("alice@a.test") is None
    assert s.add("Alice", "a.test") == "alice@a.test"
    s.add("bob@b.test")
    s.add("alice@a.test")  # duplicate
    assert s.stars_file.read_text() == "alice@a.test\nbob@b.test\n"
    assert "ALICE@a.test" in s and "@bob@b.test" in s
    s.mark_seen("alice@a.test", 10)
    s.mark_seen("alice@a.test", 5)  # never moves backwards
    assert s.last_seen("alice@a.test") == 10
    assert s.state_file.read_text() == "alice@a.test\t10\n"
    assert s.remove("alice", "a.test") and not s.remove("nobody@x.test")
    assert s.list() == ["bob@b.test"] and s.last_seen("alice@a.test") is None
    assert not list(s.stars_file.parent.glob(".*tmp*")), "atomic write left a temp file"


def test_stars_reads_bash_written_files():
    s = Stars("default")
    s.stars_file.parent.mkdir(parents=True)
    s.stars_file.write_text("# written by luti.sh\nbob@b.test\n")
    s.state_file.parent.mkdir(parents=True)
    s.state_file.write_text("bob@b.test\t99\n")
    assert s.list() == ["bob@b.test"] and s.last_seen("bob@b.test") == 99
    s.mark_seen("bob@b.test", 100)
    assert s.state_file.read_text() == "bob@b.test\t100\n"
    s.add("alice@a.test")  # the Bash CLI keeps leading comments; so do we
    assert s.stars_file.read_text() == "# written by luti.sh\nalice@a.test\nbob@b.test\n"
    assert oct(s.stars_file.stat().st_mode & 0o777) == oct(0o600)


def _post(pid: int, name: str, host: str) -> Post:
    return Post(id=pid, title=f"p{pid}", creator=Person(id=1, name=name, ap_id=f"https://{host}/u/{name}"))


def test_unread_detection_and_mark_all():
    s = Stars("default")
    s.add("alice@a.test")
    s.mark_seen("alice@a.test", 10)
    old, new = _post(9, "Alice", "a.test"), _post(11, "alice", "a.test")
    assert s.author_of(new) == "alice@a.test"
    assert s.is_seen(old) and not s.is_seen(new)
    s.mark_all_seen([old, new, _post(3, "zed", "z.test")])
    assert s.last_seen("alice@a.test") == 11 and s.last_seen("zed@z.test") == 3


def test_home_domain_of():
    assert home_domain_of({"site_view": {"site": {"ap_id": "https://lemmy.test/"}}}) == "lemmy.test"
    assert home_domain_of({"site_view": {"site": {"actor_id": "http://old.test"}}}) == "old.test"
    assert home_domain_of(None) is None


def test_stars_rejects_bad_profile():
    with pytest.raises(ValueError):
        Stars("../etc")


# -- integration ----------------------------------------------------------------
async def _session(base: str, user: str) -> Lemmy:
    lemmy = Lemmy(LemmyClient(base))
    await lemmy.login(user, USER_PW)
    await lemmy.load_me()
    return lemmy


@pytest.mark.integration
async def test_stargaze_end_to_end(server):
    _version, base = server
    alice = await _session(base, "alice")
    reader = Lemmy(LemmyClient(base))  # stargazing works anonymously too
    try:
        stars = Stars("default")
        domain = await stars.home_domain(reader)
        assert domain and "localhost" in domain
        who = stars.add("alice", domain)
        stars.add(f"nosuchuser{unique('')}", domain)

        newest = await stars.baseline(reader, who)  # a new star starts at their newest post
        assert stars.last_seen(who) == newest
        assert [p for p in await stars.stargaze(reader) if stars.author_of(p) == who] == []
        assert any("nosuchuser" in w for w in stars.warnings)  # unknown user: warning, not an exception

        community = await alice.community(name="lutidev")
        first = await alice.create_post(community.id, unique("stargaze one "))
        second = await alice.create_post(community.id, unique("stargaze two "))

        peeked = await stars.stargaze(reader, peek=True, user=who)
        assert [p.id for p in peeked][-2:] == [first.id, second.id]  # oldest first
        assert (await stars.unread_counts(reader))[who] >= 2

        stars.mark_seen(who, first.id)
        assert [p.id for p in await stars.stargaze(reader, user=who)] == [second.id]
        stars.mark_seen(who, second.id)
        assert await stars.stargaze(reader, user=who) == []
        assert stars.last_seen(who) == second.id
    finally:
        await alice.aclose()
        await reader.aclose()
