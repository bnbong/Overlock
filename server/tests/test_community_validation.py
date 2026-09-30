"""공유 허브 업로드 검증 테스트 (422: 형식·수치·필드·텍스트·기하·아이템)."""

from __future__ import annotations

import json

import pytest

from conftest import load_community_fixture

URL = "/api/community/tracks"


def _post_raw(client, raw: str | bytes):
    return client.post(URL, content=raw, headers={"Content-Type": "application/json"})


def _assert_422(resp, *, loc_contains: str | None = None, msg_contains: str | None = None):
    assert resp.status_code == 422, resp.text
    detail = resp.json()["detail"]
    assert isinstance(detail, list) and detail, detail
    for entry in detail:
        assert set(entry) == {"loc", "msg", "type"}  # 입력값(input) 에코 없음
    if loc_contains is not None:
        assert any(loc_contains in [str(x) for x in e["loc"]] for e in detail), detail
    if msg_contains is not None:
        assert any(msg_contains in e["msg"] for e in detail), detail
    return detail


# ---------------------------------------------------------------------------
# JSON 형식
# ---------------------------------------------------------------------------
def test_not_json(client):
    _assert_422(_post_raw(client, "not json"))
    _assert_422(_post_raw(client, ""))
    _assert_422(_post_raw(client, "[1, 2]"), msg_contains="객체")


@pytest.mark.parametrize("literal", ["NaN", "Infinity", "-Infinity"])
def test_nan_infinity_literals_rejected(client, make_community_payload, literal):
    raw = json.dumps(make_community_payload())
    raw = raw.replace('"fail": 90', f'"fail": {literal}', 1)
    assert literal in raw
    _assert_422(_post_raw(client, raw))


def test_overflowing_float_rejected(client, make_community_payload):
    raw = json.dumps(make_community_payload())
    raw = raw.replace("[0.0, 0.0]", "[1e400, 0.0]", 1)
    assert "1e400" in raw
    _assert_422(_post_raw(client, raw))


def test_nan_coordinate_rejected(client, make_community_payload):
    raw = json.dumps(make_community_payload()).replace("[0.0, 0.0]", "[NaN, 0.0]", 1)
    _assert_422(_post_raw(client, raw))


def test_deep_json_rejected_before_parse(client, make_community_payload):
    payload = make_community_payload()
    payload["extra"] = "__DEEP__"
    deep = "[" * 100000 + "]" * 100000
    raw = json.dumps(payload).replace('"__DEEP__"', deep)
    detail = _assert_422(_post_raw(client, raw))
    assert detail[0]["type"] == "json_too_deep"


def test_moderately_deep_json_rejected(client, make_community_payload):
    payload = make_community_payload()
    payload["track"]["items"] = [[[[[[[1]]]]]]]
    detail = _assert_422(client.post(URL, json=payload))
    assert detail[0]["type"] == "json_too_deep"


def test_brackets_inside_strings_do_not_count_as_depth(client, make_community_payload):
    resp = client.post(URL, json=make_community_payload(description="[[[[[[[[[[{{{{{{{{{{"))
    assert resp.status_code == 201, resp.text


# ---------------------------------------------------------------------------
# 스키마: 필드·형·지원 목록
# ---------------------------------------------------------------------------
def test_unknown_top_level_field(client, make_community_payload):
    _assert_422(client.post(URL, json=make_community_payload(evil=1)), loc_contains="evil")


def test_unknown_track_field(client, make_community_payload):
    p = make_community_payload()
    p["track"]["physics_override"] = {"speed": 9999}
    _assert_422(client.post(URL, json=p), loc_contains="physics_override")


def test_missing_required(client, make_community_payload):
    p = make_community_payload()
    del p["track"]["width"]
    _assert_422(client.post(URL, json=p), loc_contains="width")
    p = make_community_payload()
    del p["title"]
    _assert_422(client.post(URL, json=p), loc_contains="title")


@pytest.mark.parametrize(
    "mutate,loc",
    [
        (lambda t: t["width"].update(fail=True), "fail"),
        (lambda t: t["width"].update(fail="90"), "fail"),
        (lambda t: t["path"][0]["points"].__setitem__(0, ["0", 0]), "points"),
        (lambda t: t["path"][0]["points"].__setitem__(0, [True, 0]), "points"),
        (lambda t: t["path"][0].update(closed=0), "closed"),
        (lambda t: t.update(items=[{"s": "5", "type": "thimble", "lat": 0}]), "s"),
        (lambda t: t.update(items=[{"s": False, "type": "thimble", "lat": 0}]), "s"),
        (lambda t: t.update(is_custom="yes"), "is_custom"),
    ],
)
def test_no_implicit_bool_or_string_to_number(client, make_community_payload, mutate, loc):
    p = make_community_payload()
    mutate(p["track"])
    _assert_422(client.post(URL, json=p), loc_contains=loc)


def test_unsupported_segment_type(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"] = [
        {"type": "bezier", "p0": [0, 0], "p1": [10, 0], "p2": [20, 0], "p3": [30, 0]}
    ]
    _assert_422(client.post(URL, json=p), loc_contains="path")


def test_point_shape(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"][0]["points"][3] = [1.0, 2.0, 3.0]
    _assert_422(client.post(URL, json=p), loc_contains="points")


@pytest.mark.parametrize(
    "field,value",
    [("difficulty", "insane"), ("fabric", "plastic"), ("editor_version", "9.9.9")],
)
def test_unsupported_enums(client, make_community_payload, field, value):
    p = make_community_payload()
    p["track"][field] = value
    _assert_422(client.post(URL, json=p), loc_contains=field, msg_contains="지원하지 않는")


def test_unsupported_item_type(client, make_community_payload):
    p = make_community_payload()
    p["track"]["items"] = [{"s": 100, "type": "rocket", "lat": 0}]
    _assert_422(client.post(URL, json=p), loc_contains="type")


def test_unknown_item_field(client, make_community_payload):
    p = make_community_payload()
    p["track"]["items"] = [{"s": 100, "type": "thimble", "lat": 0, "respawn": 3}]
    _assert_422(client.post(URL, json=p), loc_contains="respawn")


def test_nonempty_modifiers_rejected(client, make_community_payload):
    p = make_community_payload()
    p["track"]["modifiers"] = [{"s": 900, "type": "slippery", "duration": 300, "strength": 0.4}]
    _assert_422(client.post(URL, json=p), loc_contains="modifiers")


def test_optional_fields_may_be_absent(client, make_community_payload):
    p = make_community_payload()
    for k in ("track_id", "name", "modifiers"):
        p["track"].pop(k, None)
    p.pop("description")
    resp = client.post(URL, json=p)
    assert resp.status_code == 201, resp.text
    assert resp.json()["description"] == ""
    assert resp.json()["track"]["items"] == []


# ---------------------------------------------------------------------------
# 폭·좌표·점 수
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "width",
    [
        {"perfect": 42, "safe": 18, "fail": 90},  # 순서 위반
        {"perfect": 18, "safe": 90, "fail": 90},  # 같은 값
        {"perfect": 0, "safe": 42, "fail": 90},  # 0
        {"perfect": -1, "safe": 42, "fail": 90},  # 음수
        {"perfect": 18, "safe": 42, "fail": 1000.5},  # 상한 초과
    ],
)
def test_width_rules(client, make_community_payload, width):
    p = make_community_payload()
    p["track"]["width"] = width
    _assert_422(client.post(URL, json=p))


def test_width_upper_bound_inclusive(client, make_community_payload):
    p = make_community_payload()
    p["track"]["width"] = {"perfect": 10, "safe": 20, "fail": 30}
    assert client.post(URL, json=p).status_code == 201


def test_coordinate_abs_limit(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"][0]["points"][0] = [16384.1, 0]
    _assert_422(client.post(URL, json=p), loc_contains="points")
    p["track"]["path"][0]["points"][0] = [0, -16384.1]
    _assert_422(client.post(URL, json=p), loc_contains="points")


def test_too_many_points(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"] = [
        {"type": "polyline", "points": [[i * 0.5, 0] for i in range(4097)], "closed": False}
    ]
    _assert_422(client.post(URL, json=p), loc_contains="points")


def test_too_many_points_across_segments(client, make_community_payload):
    p = make_community_payload()
    seg = {"type": "polyline", "points": [[i * 0.5, 0] for i in range(2049)], "closed": False}
    p["track"]["path"] = [seg, seg]
    _assert_422(client.post(URL, json=p), msg_contains="너무 많습니다")


def test_empty_path(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"] = []
    _assert_422(client.post(URL, json=p), loc_contains="path")


# ---------------------------------------------------------------------------
# 텍스트 메타데이터
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("title", ["", "   ", "\t\n"])
def test_blank_title_rejected(client, make_community_payload, title):
    _assert_422(client.post(URL, json=make_community_payload(title=title)), loc_contains="title")


def test_blank_author_rejected(client, make_community_payload):
    _assert_422(
        client.post(URL, json=make_community_payload(author_name="  ")), loc_contains="author_name"
    )


@pytest.mark.parametrize("bad", ["a\x00b", "a\x1bb", "a‮b", "a​b"])
def test_control_or_format_chars_rejected(client, make_community_payload, bad):
    _assert_422(client.post(URL, json=make_community_payload(title=bad)), loc_contains="title")
    _assert_422(
        client.post(URL, json=make_community_payload(description=bad)), loc_contains="description"
    )


def test_length_limits_after_normalization(client, make_community_payload):
    assert client.post(URL, json=make_community_payload(title="가" * 80)).status_code == 201
    _assert_422(client.post(URL, json=make_community_payload(title="가" * 81)), loc_contains="title")
    # 연속 공백은 축약된 뒤 길이를 잰다.
    assert (
        client.post(URL, json=make_community_payload(title="a" + " " * 200 + "b")).status_code == 201
    )
    assert client.post(URL, json=make_community_payload(author_name="n" * 32)).status_code == 201
    _assert_422(
        client.post(URL, json=make_community_payload(author_name="n" * 33)),
        loc_contains="author_name",
    )
    assert client.post(URL, json=make_community_payload(description="d" * 1000)).status_code == 201
    _assert_422(
        client.post(URL, json=make_community_payload(description="d" * 1001)),
        loc_contains="description",
    )
    _assert_422(client.post(URL, json=make_community_payload(title="x" * 5000)), loc_contains="title")


def test_description_keeps_single_blank_line(client, make_community_payload):
    resp = client.post(URL, json=make_community_payload(description="  a \t b\n\n\n\n c  "))
    assert resp.status_code == 201
    assert resp.json()["description"] == "a b\n\nc"


def test_html_like_text_is_stored_verbatim(client, make_community_payload):
    title = "<b>[color=red]x[/color]</b>"
    resp = client.post(URL, json=make_community_payload(title=title))
    assert resp.status_code == 201
    assert resp.json()["title"] == title  # 해석하지 않고 일반 텍스트로 보관(클라이언트가 평문 렌더)


# ---------------------------------------------------------------------------
# 기하(TrackValidator 하드 기준)
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "name",
    [
        "reject_too_few_points",
        "reject_too_short",
        "reject_too_long",
        "reject_sharp_corner",
        "reject_hairpin_proximity",
    ],
)
def test_geometry_rejections(client, make_community_payload, name):
    fx = load_community_fixture(name)
    detail = _assert_422(client.post(URL, json=make_community_payload(track=fx["track"])))
    assert all(e["type"] == "track_geometry" for e in detail)


def test_huge_coordinates_rejected_before_bake(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"][0]["points"] = [[0, 0], [16000, 0], [16000, 16000], [0, 16000]]
    detail = _assert_422(client.post(URL, json=p))
    assert "상한" in detail[0]["msg"]


# ---------------------------------------------------------------------------
# 아이템
# ---------------------------------------------------------------------------
def test_items_valid_and_range(client, make_community_payload):
    p = make_community_payload()
    p["track"]["items"] = [
        {"s": 0, "type": "thimble"},
        {"s": 1000.5, "type": "autopilot", "lat": -90},
    ]
    resp = client.post(URL, json=p)
    assert resp.status_code == 201, resp.text
    assert resp.json()["track"]["items"] == [
        {"s": 0.0, "type": "thimble", "lat": 0.0},
        {"s": 1000.5, "type": "autopilot", "lat": -90.0},
    ]

    p = make_community_payload()
    p["track"]["items"] = [{"s": 999999, "type": "thimble", "lat": 0}]
    _assert_422(client.post(URL, json=p), loc_contains="s")
    p["track"]["items"] = [{"s": -1, "type": "thimble", "lat": 0}]
    _assert_422(client.post(URL, json=p), loc_contains="s")
    p["track"]["items"] = [{"s": 10, "type": "thimble", "lat": 90.5}]
    _assert_422(client.post(URL, json=p), loc_contains="lat")


def test_too_many_items(client, make_community_payload):
    p = make_community_payload()
    p["track"]["items"] = [{"s": 10.0 + i, "type": "thimble", "lat": 0} for i in range(128)]
    assert client.post(URL, json=p).status_code == 201
    p["track"]["items"].append({"s": 5, "type": "thimble", "lat": 0})
    _assert_422(client.post(URL, json=p), loc_contains="items")


def test_coordinates_snapped_to_tenth(client, make_community_payload):
    p = make_community_payload()
    pts = p["track"]["path"][0]["points"]
    pts[1] = [pts[1][0] + 0.04, pts[1][1] - 0.06]
    resp = client.post(URL, json=p)
    assert resp.status_code == 201, resp.text
    got = resp.json()["track"]["path"][0]["points"][1]
    for v in got:
        assert abs(v * 10 - round(v * 10)) < 1e-9
