import json

import pytest
from conftest import fx

from luti.client import (
    extract_items,
    pascal_case,
    snake_case,
    transform_params,
)
from luti.spec import load_spec, spec_path


@pytest.fixture
def spec():
    return load_spec()


def test_spec_loads_from_repo():
    s = load_spec()
    assert "post.list" in s["ops"] and s["detect"]["order"] == ["v4", "v3"]


def test_luti_spec_env_override(tmp_path, monkeypatch):
    custom = tmp_path / "endpoints.json"
    data = load_spec()
    custom.write_text(json.dumps({**data, "$comment": ["custom"]}))
    monkeypatch.setenv("LUTI_SPEC", str(custom))
    assert spec_path() == custom
    assert load_spec()["$comment"] == ["custom"]


@pytest.mark.parametrize("snake,pascal", [("most_comments", "MostComments"), ("moderator_view", "ModeratorView"),
                                          ("hot", "Hot"), ("new_comments", "NewComments")])
def test_enum_case(snake, pascal):
    assert pascal_case(snake) == pascal
    assert snake_case(pascal) == snake
    assert pascal_case(pascal) == pascal


def test_enum_fields_pascal_on_v3_only(spec):
    p = {"sort": "most_comments", "type_": "moderator_view", "limit": 5}
    assert transform_params("post.list", "v3", p, spec) == {"sort": "MostComments", "type_": "ModeratorView", "limit": 5}
    assert transform_params("post.list", "v4", p, spec) == p


@pytest.mark.parametrize("direction,v3,v4", [("up", 1, True), ("down", -1, False), ("clear", 0, None)])
def test_vote(spec, direction, v3, v4):
    assert transform_params("post.vote", "v3", {"post_id": 1, "vote": direction}, spec) == {"post_id": 1, "score": v3}
    expected = {"comment_id": 2} if v4 is None else {"comment_id": 2, "is_upvote": v4}
    assert transform_params("comment.vote", "v4", {"comment_id": 2, "vote": direction}, spec) == expected


def test_vote_rejects_bad_value(spec):
    with pytest.raises(ValueError):
        transform_params("post.vote", "v3", {"post_id": 1, "vote": "sideways"}, spec)


@pytest.mark.parametrize("rng", list(load_spec()["transforms"]["top_time"]["ranges"]))
def test_top_time_all_ranges(spec, rng):
    entry = spec["transforms"]["top_time"]["ranges"][rng]
    assert transform_params("post.list", "v3", {"sort": "top", "time_range": rng}, spec) == {"sort": entry["v3"]}
    v4 = transform_params("post.list", "v4", {"sort": "top", "time_range": rng}, spec)
    assert v4 == ({"sort": "top"} if entry["seconds"] is None else {"sort": "top", "time_range_seconds": entry["seconds"]})


def test_top_without_time_is_top_all_on_v3(spec):
    assert transform_params("post.list", "v3", {"sort": "top"}, spec) == {"sort": "TopAll"}
    assert transform_params("post.list", "v4", {"sort": "top"}, spec) == {"sort": "top"}


def test_time_range_ignored_for_other_sorts(spec):
    assert transform_params("post.list", "v3", {"sort": "hot", "time_range": "day"}, spec) == {"sort": "Hot"}
    assert transform_params("post.list", "v4", {"sort": "hot", "time_range": "day"}, spec) == {"sort": "hot"}


def test_comment_top_is_plain_top_on_v3(spec):
    assert transform_params("comment.list", "v3", {"sort": "top"}, spec) == {"sort": "Top"}


def test_unknown_time_range(spec):
    with pytest.raises(ValueError):
        transform_params("post.list", "v4", {"sort": "top", "time_range": "fortnight"}, spec)


def test_rename_v3(spec):
    p = {"person_id": 3, "ban": True, "reason": "r", "remove_or_restore_data": True, "expires_at": 99}
    assert transform_params("admin.ban", "v3", p, spec) == {
        "person_id": 3, "ban": True, "reason": "r", "remove_data": True, "expires": 99}
    assert transform_params("admin.ban", "v4", p, spec) == p
    assert transform_params("community.ban", "v3", p, spec)["remove_data"] is True
    assert transform_params("search", "v3", {"search_term": "x", "type_": "posts"}, spec) == {"q": "x", "type_": "Posts"}


def test_fixed_params(spec):
    assert transform_params("pm.list", "v4", {"unread_only": True}, spec) == {"unread_only": True, "type_": "private_message"}
    assert transform_params("pm.list", "v3", {"unread_only": True}, spec) == {"unread_only": True}


def test_spec_report_types_are_plural_on_v4(spec):
    for op, plural in (("report.list.post", "posts"), ("report.list.comment", "comments"), ("report.list.pm", "private_messages")):
        assert transform_params(op, "v4", {}, spec) == {"type_": plural}


def test_none_values_dropped(spec):
    assert transform_params("post.list", "v4", {"sort": "new", "community_id": None}, spec) == {"sort": "new"}


def test_extract_items(spec):
    assert len(extract_items("post.list", "v3", fx("v3_post_list"), spec)) == len(fx("v3_post_list")["posts"])
    assert len(extract_items("post.list", "v4", fx("v4_post_list"), spec)) == len(fx("v4_post_list")["items"])


def test_extract_search_multi_list(spec):
    for v in ("v3", "v4"):
        items = extract_items("search", v, fx(f"{v}_search"), spec)
        kinds = {i["_kind"] for i in items}
        assert "post" in kinds and "community" in kinds


def test_extract_v3_person_content(spec):
    items = extract_items("person.content", "v3", fx("v3_person_get"), spec)
    assert items and all("comment" in i for i in items if i["_kind"] == "comment")


def test_extract_v3_modlog_flattened(spec):
    items = extract_items("modlog", "v3", fx("v3_modlog_full"), spec)
    data = fx("v3_modlog_full")
    assert len(items) == sum(len(v) for v in data.values() if isinstance(v, list))
    assert {i["_kind"] for i in items} >= {"removed_posts", "banned_from_community"}
