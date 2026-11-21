import os
import stat

import pytest

from luti_tui.config import Profile, config_root, format_config, list_profiles, parse_config, valid_profile_name


def test_config_root_uses_xdg(isolated_config):
    assert config_root() == isolated_config / "luti"


def test_config_root_default(monkeypatch, tmp_path):
    monkeypatch.delenv("XDG_CONFIG_HOME")
    monkeypatch.setenv("HOME", str(tmp_path))
    assert config_root() == tmp_path / ".config" / "luti"


def test_parse_plain_and_quoted():
    text = '''# luti profile
instance="https://lemmy.example"
username=alice
mfa=true
api='v4'

  junk line without equals
export extra="a \\"quoted\\" value"
'''
    assert parse_config(text) == {
        "instance": "https://lemmy.example", "username": "alice", "mfa": "true", "api": "v4",
        "extra": 'a "quoted" value',
    }


def test_format_round_trip():
    values = {"username": "bob", "instance": "https://x.y", "mfa": "false", "note": 'has space "and" $dollar'}
    text = format_config(values)
    assert text.splitlines()[:3] == ["instance=https://x.y", "username=bob", "mfa=false"]
    assert parse_config(text) == values


def test_profile_save_load(isolated_config):
    p = Profile(name="work", instance="https://lemmy.example", username="alice", mfa=True, api="v3")
    p.save()
    text = (isolated_config / "luti" / "work" / "config").read_text()
    assert text == "instance=https://lemmy.example\nusername=alice\nmfa=true\napi=v3\n"
    q = Profile.load("work")
    assert (q.instance, q.username, q.mfa, q.api) == ("https://lemmy.example", "alice", True, "v3")
    assert stat.S_IMODE(os.stat(isolated_config / "luti" / "work").st_mode) == 0o700
    assert list_profiles() == ["work"]


def test_profile_reads_bash_style_config_and_keeps_unknown_keys(isolated_config):
    d = isolated_config / "luti" / "default"
    d.mkdir(parents=True)
    (d / "config").write_text('instance="https://a.b"\nusername="carol"\nmfa="false"\nrefresh="60"\n')
    p = Profile.load("default")
    assert (p.instance, p.username, p.mfa, p.api) == ("https://a.b", "carol", False, None)
    p.save()
    assert parse_config((d / "config").read_text()) == {
        "instance": "https://a.b", "username": "carol", "mfa": "false", "refresh": "60"}


def test_api_omitted_when_auto(isolated_config):
    Profile(name="x", instance="https://a.b", username="u").save()
    assert "api" not in (isolated_config / "luti" / "x" / "config").read_text()


def test_invalid_api_value_ignored(isolated_config):
    d = isolated_config / "luti" / "x"
    d.mkdir(parents=True)
    (d / "config").write_text("instance=a\napi=v9\n")
    assert Profile.load("x").api is None


def test_token_file_permissions(isolated_config):
    p = Profile(name="default", instance="https://a.b", username="u")
    assert p.read_token() is None
    p.write_token("jwt.token.value")
    assert p.token_file.read_text() == "jwt.token.value"
    assert stat.S_IMODE(os.stat(p.token_file).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(p.dir).st_mode) == 0o700
    assert p.read_token() == "jwt.token.value"
    p.write_token("second")
    assert p.read_token() == "second"
    p.clear_token()
    assert p.read_token() is None


def test_token_file_with_newline_from_bash(isolated_config):
    p = Profile(name="default")
    p.dir.mkdir(parents=True)
    p.token_file.write_text("abc.def\n")
    assert p.read_token() == "abc.def"


def test_password_never_written(isolated_config):
    p = Profile(name="default", instance="https://a.b", username="u")
    p.save()
    p.write_token("t")
    for f in p.dir.iterdir():
        assert "password" not in f.read_text()


@pytest.mark.parametrize("name,ok", [("default", True), ("work.alt", True), ("a@b", True), ("../x", False),
                                     ("", False), ("..", False), ("a b", False)])
def test_profile_names(name, ok):
    assert valid_profile_name(name) is ok
    if not ok:
        with pytest.raises(ValueError):
            Profile.load(name)


class FakeKeyring:
    def __init__(self):
        self.store = {}

    def get_password(self, service, user):
        return self.store.get((service, user))

    def set_password(self, service, user, value):
        self.store[(service, user)] = value

    def delete_password(self, service, user):
        self.store.pop((service, user), None)


def test_keyring_used_instead_of_token_file(monkeypatch):
    import luti_tui.config as cfg

    kr = FakeKeyring()
    monkeypatch.setattr(cfg, "_keyring", lambda: kr)
    p = Profile(name="default", instance="https://a.b", username="u")
    p.dir.mkdir(parents=True)
    p.token_file.write_text("old-file-token")
    p.write_token("kr-token")
    assert kr.store[("luti", "default")] == "kr-token"
    assert not p.token_file.exists()
    assert p.read_token() == "kr-token"
    p.clear_token()
    assert p.read_token() is None


def test_keyring_falls_back_to_bash_token_file(monkeypatch):
    import luti_tui.config as cfg

    monkeypatch.setattr(cfg, "_keyring", lambda: FakeKeyring())
    p = Profile(name="default")
    p.dir.mkdir(parents=True)
    p.token_file.write_text("from-bash")
    assert p.read_token() == "from-bash"


def test_no_keyring_env_disables_keyring(monkeypatch):
    import luti_tui.config as cfg

    monkeypatch.setenv("LUTI_NO_KEYRING", "1")
    assert cfg._keyring() is None
