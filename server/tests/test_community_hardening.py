"""공유 허브 교차 리뷰 지적 회귀 테스트.

- JSON 깊이 스캐너: 적대적 1MiB 입력에서 선형 시간(예전 정규식은 O(n^2) ReDoS)
- 본문 버퍼링: POST 만 버퍼링, 초과 청크는 복사·추가 receive 없이 413
- 422 오류 응답 증폭 방지(항목 수·loc 길이 상한, 값싼 크기 검사 선행)
- float32 판정 정책: 베이크·누적 길이 float32 모사 + 서버 쪽 여유 밴드
- content_hash: -0.0 정규화, closed 제외
- 삭제 경합: 원자적 갱신(rowcount 0 → 404)
- 보이지 않는 문자만으로 된 제목·작성자명 거부, 오류 메시지 입력 에코 제거
"""

from __future__ import annotations

import asyncio
import json
import math
import time

import pytest
from sqlalchemy import select, update

from app import community as community_mod
from app import community_validation as cv
from app.main import ContentLengthLimitMiddleware
from app.models import CommunityTrack

URL = "/api/community/tracks"
MiB = 1 << 20


def _post_raw(client, raw: bytes):
    return client.post(URL, content=raw, headers={"Content-Type": "application/json"})


def _publish(client, payload) -> dict:
    resp = client.post(URL, json=payload)
    assert resp.status_code == 201, resp.text
    return resp.json()


# ---------------------------------------------------------------------------
# 1) JSON 깊이 스캐너 (ReDoS)
# ---------------------------------------------------------------------------
ADVERSARIAL_BODIES = {
    "unterminated_escaped_quotes": b'"' + b'\\"' * (MiB // 2),
    "unterminated_plain": b'"' + b"a" * MiB,
    "backslashes": b'"' + b"\\" * MiB,
    "deep_nesting": b"[" * MiB,
    "brackets_only": b"[]" * (MiB // 2),
    "brackets_in_string": b'"' + b"[{" * (MiB // 2) + b'"',
    "quotes_only": b'"' * MiB,
}


@pytest.mark.parametrize("name", sorted(ADVERSARIAL_BODIES))
def test_depth_scan_is_linear_on_adversarial_1mib(name):
    body = ADVERSARIAL_BODIES[name]
    start = time.perf_counter()
    cv.json_depth_exceeds(body, cv.MAX_JSON_DEPTH)
    assert time.perf_counter() - start < 1.5


@pytest.mark.parametrize("name", sorted(ADVERSARIAL_BODIES))
def test_validate_upload_rejects_adversarial_1mib_quickly(name):
    start = time.perf_counter()
    with pytest.raises(cv.TrackRejected):
        cv.validate_upload(ADVERSARIAL_BODIES[name])
    assert time.perf_counter() - start < 2.0


def test_depth_scan_string_and_escape_state():
    # 이스케이프된 따옴표는 문자열을 닫지 않는다 → 뒤의 괄호는 문자열 안이다.
    assert not cv.json_depth_exceeds(b'{"a": "x\\"[[[[[[[[[[[["}', 8)
    # 이스케이프된 역슬래시 뒤의 따옴표는 문자열을 닫는다 → 뒤의 괄호는 깊이에 들어간다.
    assert cv.json_depth_exceeds(b'{"a": "x\\\\", "b": [[[[[[[[1]]]]]]]]}', 8)
    assert not cv.json_depth_exceeds(b'{"a": "x\\\\", "b": [[[[[[1]]]]]]}', 8)
    # 경계: 깊이 8 은 허용, 9 는 초과.
    assert not cv.json_depth_exceeds(b"[" * 8 + b"]" * 8, 8)
    assert cv.json_depth_exceeds(b"[" * 9 + b"]" * 9, 8)


def test_depth_scan_matches_parser_depth_on_real_payload(make_community_payload):
    raw = json.dumps(make_community_payload(description='q"[{\\"}]')).encode()
    assert not cv.json_depth_exceeds(raw, cv.MAX_JSON_DEPTH)
    assert not cv.json_depth_exceeds(raw, 6)
    assert cv.json_depth_exceeds(raw, 5)  # 정상 업로드 최대 깊이는 6


# ---------------------------------------------------------------------------
# 2)·3) 본문 버퍼링 범위와 청크 검사 순서
# ---------------------------------------------------------------------------
def _drive(method: str, chunks: list[bytes], headers=(), limit: int = 100):
    """미들웨어를 직접 호출해 receive 호출 수·하위 앱 도달 여부·응답 상태를 기록한다."""
    messages = [
        {"type": "http.request", "body": c, "more_body": i < len(chunks) - 1}
        for i, c in enumerate(chunks)
    ]
    log = {"receive_calls": 0, "app": False, "app_body": b"", "status": None}

    async def receive():
        log["receive_calls"] += 1
        if messages:
            return messages.pop(0)
        return {"type": "http.disconnect"}

    async def send(message):
        if message["type"] == "http.response.start":
            log["status"] = message["status"]

    async def inner(scope, receive, send):
        log["app"] = True
        body = b""
        while True:
            m = await receive()
            body += m.get("body", b"")
            if not m.get("more_body"):
                break
        log["app_body"] = body
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})

    mw = ContentLengthLimitMiddleware(
        inner, max_body_bytes=16, streamed_prefixes=(("/api/community/", limit),)
    )
    scope = {"type": "http", "method": method, "path": "/api/community/tracks", "headers": list(headers)}
    asyncio.run(mw(scope, receive, send))
    return log


def test_oversized_first_chunk_rejected_without_more_receive():
    log = _drive("POST", [b"x" * 4000, b"y" * 10, b"z" * 10])
    assert log["status"] == 413
    assert log["receive_calls"] == 1  # 초과 판정 뒤 더 읽지 않는다
    assert log["app"] is False


def test_crossing_chunk_stops_reading_immediately():
    log = _drive("POST", [b"a" * 60, b"b" * 60, b"c" * 10])
    assert log["status"] == 413
    assert log["receive_calls"] == 2
    assert log["app"] is False


def test_exact_limit_is_accepted_and_replayed():
    log = _drive("POST", [b"a" * 50, b"b" * 50])
    assert log["status"] == 200
    assert log["app_body"] == b"a" * 50 + b"b" * 50


@pytest.mark.parametrize("method", ["GET", "DELETE", "OPTIONS", "HEAD"])
def test_non_body_methods_are_not_buffered(method):
    # 버퍼링하지 않으므로 미들웨어는 receive 를 호출하지 않고 하위 앱이 직접 읽는다.
    log = _drive(method, [b"x" * 60, b"y" * 60])
    assert log["app"] is True
    assert log["status"] == 200
    assert log["app_body"] == b"x" * 60 + b"y" * 60


@pytest.mark.parametrize("method", ["GET", "DELETE"])
def test_non_body_methods_keep_declared_length_check(method):
    log = _drive(method, [b""], headers=[(b"content-length", b"101")])
    assert log["status"] == 413
    assert log["app"] is False


def test_get_and_delete_still_work_through_app(client, make_community_payload):
    created = _publish(client, make_community_payload())
    assert client.get(URL).status_code == 200
    assert client.get(f"{URL}/{created['id']}").status_code == 200
    r = client.delete(
        f"{URL}/{created['id']}", headers={"Authorization": f"Bearer {created['delete_token']}"}
    )
    assert r.status_code == 204


# ---------------------------------------------------------------------------
# 4) 422 오류 응답 증폭 방지
# ---------------------------------------------------------------------------
def test_many_bad_points_capped_detail(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"][0]["points"] = [["x", "y"]] * 4096
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    detail = resp.json()["detail"]
    assert len(detail) <= cv.MAX_ERROR_ITEMS
    assert detail[-1]["type"] == "too_many_errors"
    assert len(resp.content) < 8 * 1024


def test_many_unknown_keys_capped_detail(client, make_community_payload):
    p = make_community_payload(**{f"k{i}": 1 for i in range(20000)})
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    assert len(resp.json()["detail"]) <= cv.MAX_ERROR_ITEMS
    assert len(resp.content) < 8 * 1024


def test_long_unknown_key_not_echoed(client, make_community_payload):
    key = "k" * 500_000
    resp = client.post(URL, json=make_community_payload(**{key: 1}))
    assert resp.status_code == 422
    assert len(resp.content) < 2 * 1024


def test_oversized_point_rejected_by_prescan_with_one_error(client, make_community_payload):
    p = make_community_payload()
    p["track"]["path"][0]["points"][1] = ["x"] * 100_000
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    detail = resp.json()["detail"]
    assert len(detail) == 1 and detail[0]["type"] == "point_shape"
    assert detail[0]["loc"] == ["body", "track", "path", 0, "points", 1]


def test_too_many_segments_rejected_by_prescan(client, make_community_payload):
    p = make_community_payload()
    seg = {"type": "polyline", "points": [[0, 0], [1, 0]]}
    p["track"]["path"] = [seg] * (cv.MAX_SEGMENTS + 1)
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    assert len(resp.json()["detail"]) == 1


def test_cap_errors_keeps_short_lists():
    errs = [{"loc": ["body"], "msg": str(i), "type": "x"} for i in range(cv.MAX_ERROR_ITEMS)]
    assert cv.cap_errors(errs) == errs
    capped = cv.cap_errors(errs + errs)
    assert len(capped) == cv.MAX_ERROR_ITEMS
    assert str(2 * cv.MAX_ERROR_ITEMS) in capped[-1]["msg"]


# ---------------------------------------------------------------------------
# 5) float32 판정 정책
# ---------------------------------------------------------------------------
def _straight(length: float, ox: float = 0.0, oy: float = 0.0):
    return [[(ox, oy), (ox + length, oy)]]


def test_f32_rounding():
    assert cv.f32(0.1) == 0.10000000149011612
    assert cv.f32(1500.3) != 1500.3
    assert cv.f32(cv.f32(1500.3)) == cv.f32(1500.3)
    assert cv.f32(6.0) == 6.0


def test_bake_uses_float32_points_and_arc_lengths():
    baked = cv.bake_track(_straight(1500.3, 12345.6, -9876.5))
    for x, y in baked.points:
        assert cv.f32(x) == x and cv.f32(y) == y
    for s in baked.s_arr:
        assert cv.f32(s) == s
    assert baked.s_arr == cv.build_arc_lengths(baked.points)
    # 비감소(PackedFloat32Array 누적)
    assert all(b >= a for a, b in zip(baked.s_arr, baked.s_arr[1:]))


def test_accept_stadium_expert_baked_count_matches_godot():
    # 실제 Godot(4.6, macOS arm64) TrackData.bake 결과 489 점. float64 베이크는 490 이었다.
    from conftest import load_community_fixture

    track = load_community_fixture("accept_stadium_expert")["track"]
    segs = [[(float(x), float(y)) for x, y in seg["points"]] for seg in track["path"]]
    assert len(cv.bake_polyline(segs)) == 489


@pytest.mark.parametrize(
    "length,conservative_ok,exact_ok",
    [
        (1499.9, False, False),
        (1500.2, False, True),  # 밴드 안: 서버는 거부, 원본 임계값은 수락
        (1500.6, True, True),
        (7999.4, True, True),
        (7999.8, False, True),
        (8000.2, False, False),
    ],
)
def test_length_band(length, conservative_ok, exact_ok):
    baked = cv.bake_track(_straight(length, 3000.0, 3000.0))
    cons = cv.validate_geometry(baked.points, 90.0, s_arr=baked.s_arr)
    exact = cv.validate_geometry(baked.points, 90.0, s_arr=baked.s_arr, conservative=False)
    assert cons.ok is conservative_ok, cons.messages
    assert exact.ok is exact_ok


def test_codex_large_coordinate_case_now_rejected_by_coord_limit(client, make_community_payload):
    # 리뷰 재현값: float64 1499.998(거부) / float32 1500.0004(통과). 좌표 상한으로 원천 차단한다.
    p = make_community_payload()
    p["track"]["path"] = [{"type": "polyline", "points": [[98000, 98000], [99132.4, 98983.7]]}]
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    assert any("points" in [str(x) for x in e["loc"]] for e in resp.json()["detail"])


def test_server_verdict_never_looser_than_exact_port():
    # 보수 판정이 수락하면 원본 임계값(Godot 와 같은 float32 계산)도 반드시 수락한다.
    import random

    rng = random.Random(7)
    accepted = 0
    for _ in range(60):
        ox, oy = rng.uniform(-15000, 15000), rng.uniform(-15000, 15000)
        base = rng.uniform(250, 1100)
        m = rng.choice([60, 300, 900])
        phase = rng.uniform(0, 2 * math.pi)
        wobble = rng.uniform(0.0, 0.3)
        pts = []
        for t in range(m):
            th = 2 * math.pi * t / m * 0.93
            r = base * (1 + wobble * math.cos(3 * th + phase))
            pts.append((cv.snap01(ox + r * math.cos(th)), cv.snap01(oy + r * math.sin(th))))
        baked = cv.bake_track([pts])
        fail = rng.choice([30.0, 90.0])
        cons = cv.validate_geometry(baked.points, fail, s_arr=baked.s_arr)
        exact = cv.validate_geometry(baked.points, fail, s_arr=baked.s_arr, conservative=False)
        accepted += int(cons.ok)
        if cons.ok:
            assert exact.ok
        # 클러스터 개수는 묶음 방식 때문에 단조가 아니지만 "하드 존재" 여부는 단조다.
        if exact.hard_curvature:
            assert cons.hard_curvature
        assert cons.hard_proximity >= exact.hard_proximity
    assert accepted >= 10  # 수락 사례도 충분히 섞였는지


def test_curvature_band():
    # 반경이 MIN_RADIUS 바로 위인 원호: 원본 임계값은 수락, 보수 판정은 밴드 안이면 거부.
    def arc_track(r):
        pts = [(-800.0 + t, 0.0) for t in range(0, 800, 40)]
        n = 60
        for a in range(n + 1):
            th = -math.pi / 2 + math.pi * a / n
            pts.append((r * math.cos(th), r + r * math.sin(th)))
        pts += [(-t, 2 * r) for t in range(40, 900, 40)]
        return [[(cv.snap01(x), cv.snap01(y)) for x, y in pts]]

    results = {}
    for r in (27.0, 28.4, 29.5):
        baked = cv.bake_track(arc_track(r))
        cons = cv.validate_geometry(baked.points, 20.0, s_arr=baked.s_arr)
        exact = cv.validate_geometry(baked.points, 20.0, s_arr=baked.s_arr, conservative=False)
        results[r] = (cons.hard_curvature > 0, exact.hard_curvature > 0)
    assert results[27.0] == (True, True)
    assert results[29.5] == (False, False)
    # 공칭 28.4: 스텐실(±15px) 반경은 약 28.06 으로 28 과 28 + RADIUS_MARGIN 사이 → 보수 판정만 하드
    assert results[28.4] == (True, False)


def test_items_must_leave_margin_before_track_end(client, make_community_payload):
    p = make_community_payload()
    length = _publish(client, make_community_payload())["length"]
    p["track"]["items"] = [{"s": length + 0.4, "type": "thimble", "lat": 0}]
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    assert any("s" in [str(x) for x in e["loc"]] for e in resp.json()["detail"])
    p["track"]["items"] = [{"s": length - 2, "type": "thimble", "lat": 0}]
    assert client.post(URL, json=p).status_code == 201


def test_subdivision_ambiguity_detector():
    f = cv.f32
    # 축 정렬 구간은 FMA 와 무관 → 모호하지 않다.
    assert not cv._subdiv_ambiguous(f(100.1), f(200.2), f(160.1), f(200.2), cv._dist32(f(100.1), f(200.2), f(160.1), f(200.2)))
    # (3.6, 4.8) 피타고라스 구간: 모든 평가 순서가 같은 float32 거리(6.0)를 낸다 → 모호하지 않다.
    ax, ay, bx, by = f(-389.3), f(110.6), f(-392.9), f(105.8)
    d = cv._dist32(ax, ay, bx, by)
    assert d == 6.0
    assert not cv._subdiv_ambiguous(ax, ay, bx, by, d)


# ---------------------------------------------------------------------------
# 6)·7) content_hash: -0.0 정규화, closed 제외
# ---------------------------------------------------------------------------
def test_negative_zero_normalized_in_hash_and_storage(client, make_community_payload):
    base = make_community_payload()
    base["track"]["items"] = [{"s": 0.0, "type": "thimble", "lat": 0.0}]
    neg = make_community_payload()
    neg["track"]["items"] = [{"s": -0.0, "type": "thimble", "lat": -0.0}]
    pts = neg["track"]["path"][0]["points"]
    assert pts[0] == [0.0, 0.0]
    pts[0] = [-0.0, -0.0]
    raw = json.dumps(neg).encode()
    assert b"-0.0" in raw
    a = _publish(client, base)
    resp = _post_raw(client, raw)
    assert resp.status_code == 201, resp.text
    b = resp.json()
    assert a["content_hash"] == b["content_hash"]
    assert b"-0.0" not in json.dumps(b["track"]).encode()


def test_play_data_normalizes_negative_zero_directly():
    track = {
        "difficulty": "normal",
        "fabric": "silk",
        "width": {"perfect": 18.0, "safe": 42.0, "fail": 90.0},
        "path": [{"type": "polyline", "points": [[-0.0, 1.0], [2.0, -0.0]], "closed": False}],
        "items": [{"s": -0.0, "type": "thimble", "lat": -0.0}],
    }
    pos = json.loads(json.dumps(track).replace("-0.0", "0.0"))
    assert cv.compute_content_hash(track) == cv.compute_content_hash(pos)


def test_closed_excluded_from_hash_but_kept_in_track(client, make_community_payload):
    open_p = make_community_payload()
    open_p["track"]["path"][0]["closed"] = False
    closed_p = make_community_payload()
    closed_p["track"]["path"][0]["closed"] = True
    a = _publish(client, open_p)
    b = _publish(client, closed_p)
    assert a["content_hash"] == b["content_hash"]
    assert a["track"]["path"][0]["closed"] is False
    assert b["track"]["path"][0]["closed"] is True
    assert client.get(f"{URL}/{b['id']}").json()["track"]["path"][0]["closed"] is True


def test_segment_split_still_changes_hash(client, make_community_payload):
    one = make_community_payload()
    pts = one["track"]["path"][0]["points"]
    two = make_community_payload()
    mid = len(pts) // 2
    two["track"]["path"] = [
        {"type": "polyline", "points": pts[: mid + 1], "closed": False},
        {"type": "polyline", "points": pts[mid:], "closed": False},
    ]
    a = _publish(client, one)
    b = _publish(client, two)
    assert a["length"] == b["length"]
    assert a["content_hash"] != b["content_hash"]


# ---------------------------------------------------------------------------
# 8) 삭제 경합
# ---------------------------------------------------------------------------
def test_delete_race_loser_gets_404_and_keeps_first_timestamp(
    client, make_community_payload, monkeypatch
):
    created = _publish(client, make_community_payload())
    track_id = created["id"]
    first_deleted_at = "2000-01-01T00:00:00.000000+00:00"
    original = community_mod._get_visible
    maker = client.app.state.sessionmaker

    def racing_get_visible(session, tid):
        row = original(session, tid)
        # 조회와 갱신 사이에 다른 요청이 먼저 삭제를 커밋한 상황을 만든다.
        with maker() as other:
            other.execute(
                update(CommunityTrack)
                .where(CommunityTrack.id == tid)
                .values(deleted_at=first_deleted_at)
            )
            other.commit()
        return row

    monkeypatch.setattr(community_mod, "_get_visible", racing_get_visible)
    r = client.delete(
        f"{URL}/{track_id}", headers={"Authorization": f"Bearer {created['delete_token']}"}
    )
    assert r.status_code == 404
    with maker() as s:
        row = s.scalars(select(CommunityTrack).where(CommunityTrack.id == track_id)).one()
        assert row.deleted_at == first_deleted_at


# ---------------------------------------------------------------------------
# 9)·10) 보이지 않는 문자 제목, 입력 에코 제거
# ---------------------------------------------------------------------------
INVISIBLE_ONLY = ["ㅤ", "ᅟᅠ", "⠀ ⠀", "ﾠﾠ", " ㅤ⠀ "]


@pytest.mark.parametrize("text", INVISIBLE_ONLY)
def test_invisible_only_title_and_author_rejected(client, make_community_payload, text):
    for field in ("title", "author_name"):
        resp = client.post(URL, json=make_community_payload(**{field: text}))
        assert resp.status_code == 422, (field, resp.text)
        assert any(field in e["loc"] for e in resp.json()["detail"])


def test_invisible_chars_mixed_with_visible_text_allowed(client, make_community_payload):
    resp = client.post(URL, json=make_community_payload(title="가ㅤ나", author_name="a⠀b"))
    assert resp.status_code == 201, resp.text


@pytest.mark.parametrize(
    "field,allowed",
    [("difficulty", "beginner"), ("fabric", "cotton"), ("editor_version", "0.1.0")],
)
def test_unsupported_value_not_echoed(client, make_community_payload, field, allowed):
    p = make_community_payload()
    p["track"][field] = "SECRET_VALUE_42"
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    assert "SECRET_VALUE_42" not in resp.text
    assert any(allowed in e["msg"] and "허용" in e["msg"] for e in resp.json()["detail"])


def test_unsupported_item_type_not_echoed(client, make_community_payload):
    p = make_community_payload()
    p["track"]["items"] = [{"s": 10, "type": "SECRET_ROCKET", "lat": 0}]
    resp = client.post(URL, json=p)
    assert resp.status_code == 422
    assert "SECRET_ROCKET" not in resp.text
    assert "thimble" in resp.text
