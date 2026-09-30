"""기하 포팅 검증: 공통 fixture 판정·길이, 그리고 GDScript 를 문자 그대로 옮긴 참조 구현과의 일치.

참조 구현(_ref_*)은 TrackValidator.gd 를 최적화 없이 줄 단위로 옮긴 것이다(선형 _span_index,
셀=1.5·fail 공간 해시 자기근접, _dedupe_pairs). 서버 구현(app.community_validation)은 같은
결과를 이진탐색·건너뛰기로 빠르게 계산하므로, 무작위 폴리라인에서 하드 판정이 같아야 한다.
"""

from __future__ import annotations

import json
import math
import random

import pytest

from app import community_validation as cv
from conftest import COMMUNITY_FIXTURES_DIR, load_community_fixture

FIXTURE_NAMES = sorted(p.stem for p in COMMUNITY_FIXTURES_DIR.glob("*.json"))


# ---------------------------------------------------------------------------
# GDScript 문자 그대로의 참조 구현
# ---------------------------------------------------------------------------
def _ref_span_index(s_arr, i, direction):
    n = len(s_arr)
    j = i
    while j > 0 and j < n - 1:
        j += direction
        if abs(s_arr[j] - s_arr[i]) >= cv.CURV_SPAN:
            return j
    if j >= 0 and j < n and abs(s_arr[j] - s_arr[i]) >= cv.CURV_SPAN * 0.6:
        return j
    return -1


def _ref_curvature(pts, s_arr):
    raw = []
    for i in range(len(pts)):
        kb = _ref_span_index(s_arr, i, -1)
        kf = _ref_span_index(s_arr, i, 1)
        if kb < 0 or kf < 0:
            continue
        r = cv.menger_radius(pts[kb], pts[i], pts[kf])
        if r < cv.RADIUS_RECOMMEND:
            raw.append({"i": i, "radius": r, "kind": "hard" if r < cv.MIN_RADIUS else "soft"})
    if not raw:
        return raw
    out = []
    cur = raw[0]
    last_i = raw[0]["i"]
    for v in raw[1:]:
        if v["i"] - last_i <= 6:
            if v["radius"] < cur["radius"]:
                cur = v
        else:
            out.append(cur)
            cur = v
        last_i = v["i"]
    out.append(cur)
    return out


def _ref_proximity(pts, s_arr, fail):
    out = []
    if fail <= 0.0:
        return out
    cell = fail * 1.5
    reach2 = cell * cell
    grid = {}
    for i, p in enumerate(pts):
        grid.setdefault((math.floor(p[0] / cell), math.floor(p[1] / cell)), []).append(i)
    for i, p in enumerate(pts):
        ci = (math.floor(p[0] / cell), math.floor(p[1] / cell))
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((ci[0] + dx, ci[1] + dy), ()):
                    if j <= i:
                        continue
                    d2 = (pts[j][0] - p[0]) ** 2 + (pts[j][1] - p[1]) ** 2
                    if d2 > reach2:
                        continue
                    ds = abs(s_arr[i] - s_arr[j])
                    if ds <= cv.ARC_EXEMPT:
                        continue
                    d = math.sqrt(d2)
                    if ds <= cv.RELOCALIZE_REACH and d < fail:
                        out.append({"i": i, "j": j, "kind": "hard", "d": d})
                    elif d < fail * 1.5:
                        out.append({"i": i, "j": j, "kind": "soft", "d": d})
    best = {}
    for v in out:
        key = (v["i"] // 16, v["j"] // 16, v["kind"])
        if key not in best or v["d"] < best[key]["d"]:
            best[key] = v
    return list(best.values())


def _ref_validate(pts, fail):
    """TrackValidator.validate 의 ok·length·hard 개수만 반환."""
    if len(pts) < cv.MIN_POINTS:
        return {"ok": False, "length": 0.0, "hard_curv": 0, "hard_prox": 0}
    s_arr = cv.build_arc_lengths(pts)
    total = s_arr[-1]
    hard_curv = sum(1 for v in _ref_curvature(pts, s_arr) if v["kind"] == "hard")
    len_hard = 1 if (total < cv.LEN_HARD_MIN or total > cv.LEN_HARD_MAX) else 0
    hard_prox = sum(1 for v in _ref_proximity(pts, s_arr, fail) if v["kind"] == "hard")
    return {
        "ok": hard_curv + hard_prox + len_hard == 0,
        "length": total,
        "hard_curv": hard_curv,
        "hard_prox": hard_prox,
    }


def _bake_fixture(track):
    segs = [[(float(x), float(y)) for x, y in seg["points"]] for seg in track["path"]]
    return cv.bake_polyline(segs)


# ---------------------------------------------------------------------------
# 공통 fixture
# ---------------------------------------------------------------------------
def test_fixture_set_has_both_kinds():
    kinds = {load_community_fixture(n)["expect"] for n in FIXTURE_NAMES}
    assert kinds == {"accept", "reject"}
    assert len(FIXTURE_NAMES) >= 8


@pytest.mark.parametrize("name", FIXTURE_NAMES)
def test_fixture_verdict_and_length(name):
    fx = load_community_fixture(name)
    assert fx["expect"] in ("accept", "reject")
    track = fx["track"]
    fail = float(track["width"]["fail"])
    baked = _bake_fixture(track)
    geo = cv.validate_geometry(baked, fail)
    assert ("accept" if geo.ok else "reject") == fx["expect"], geo.messages
    assert abs(geo.length - fx["expected_length"]) <= fx["length_tolerance"]
    assert geo.baked_points == fx["expected_baked_points"]
    # 참조(문자 그대로) 구현과 같은 판정·같은 하드 개수.
    ref = _ref_validate(baked, fail)
    assert ref["ok"] == geo.ok
    assert ref["hard_curv"] == geo.hard_curvature
    assert ref["hard_prox"] == geo.hard_proximity


@pytest.mark.parametrize("name", FIXTURE_NAMES)
def test_fixture_through_full_upload_validation(name):
    fx = load_community_fixture(name)
    body = json.dumps({"title": name, "author_name": "fixture", "track": fx["track"]}).encode()
    if fx["expect"] == "accept":
        result = cv.validate_upload(body)
        # 응답 length 는 베이크 길이를 정수로 반올림한 값(expected_length 는 소수 1자리 반올림).
        assert abs(result.length - fx["expected_length"]) <= 0.5 + fx["length_tolerance"]
        assert result.track["length"] == result.length
    else:
        with pytest.raises(cv.TrackRejected) as exc:
            cv.validate_upload(body)
        assert all(e["type"] == "track_geometry" for e in exc.value.errors)


# ---------------------------------------------------------------------------
# 무작위 폴리라인: 최적화 구현 == 참조 구현
# ---------------------------------------------------------------------------
def _random_walk(rng: random.Random, n: int, step_lo: float, step_hi: float, turn: float):
    x = y = 0.0
    heading = rng.uniform(-math.pi, math.pi)
    pts = [(0.0, 0.0)]
    for _ in range(n):
        heading += rng.uniform(-turn, turn)
        step = rng.uniform(step_lo, step_hi)
        if rng.random() < 0.03:
            step = 0.0  # 중복점(0 길이 세그먼트)도 섞는다
        x += step * math.cos(heading)
        y += step * math.sin(heading)
        pts.append((cv.snap01(x), cv.snap01(y)))
    return pts


@pytest.mark.parametrize("seed", range(40))
def test_optimized_matches_reference_on_random_walks(seed):
    rng = random.Random(seed)
    n = rng.choice([30, 120, 400])
    turn = rng.choice([0.05, 0.2, 0.6, 1.2])
    raw = _random_walk(rng, n, 0.2, rng.choice([4.0, 12.0, 30.0]), turn)
    fail = rng.choice([30.0, 60.0, 90.0, 150.0])
    baked = cv.bake_polyline([raw])
    # 포팅 일치 검증: 여유 밴드 없이 원본과 같은 임계값으로 비교한다.
    geo = cv.validate_geometry(baked, fail, conservative=False)
    ref = _ref_validate(baked, fail)
    assert geo.ok == ref["ok"]
    assert geo.hard_curvature == ref["hard_curv"]
    assert geo.hard_proximity == ref["hard_prox"]
    assert geo.length == pytest.approx(ref["length"])


@pytest.mark.parametrize("seed", range(200))
def test_span_index_matches_reference(seed):
    rng = random.Random(1000 + seed)
    raw = _random_walk(rng, rng.choice([3, 10, 60]), 0.0, rng.choice([2.0, 8.0, 20.0]), 0.5)
    s_arr = cv.build_arc_lengths(raw)
    for i in range(len(raw)):
        for d in (-1, 1):
            assert cv._span_index(s_arr, i, d) == _ref_span_index(s_arr, i, d)


def test_bake_matches_gdscript_rules():
    # 세그먼트 경계: 다음 세그먼트 첫 점이 0.01 미만으로 같으면 건너뛴다.
    segs = [[(0.0, 0.0), (12.0, 0.0)], [(12.0, 0.0), (12.0, 13.0)]]
    baked = cv.bake_polyline(segs)
    assert baked[0] == (0.0, 0.0)
    assert (6.0, 0.0) in baked and baked.count((12.0, 0.0)) == 1
    # 13px → ceil(13/6)=3 등분
    assert len(baked) == 3 + 3
    # 같은 세그먼트 안의 중복점은 그대로 둔다(0 길이 세그먼트).
    assert cv.bake_polyline([[(0.0, 0.0), (0.0, 0.0), (1.0, 0.0)]]) == [
        (0.0, 0.0),
        (0.0, 0.0),
        (1.0, 0.0),
    ]


def test_snap_matches_snappedf():
    assert cv.snap01(0.05) == 0.1  # floor(0.5 + 0.5) = 1 → 0.1 (0.5 올림)
    assert cv.snap01(-0.05) == 0.0  # floor(-0.5 + 0.5) = 0 → 0.0
    assert cv.snap01(-0.06) == -0.1
    assert cv.snap01(123.44) == 123.4
    assert cv.snap01(123.45) in (123.4, 123.5)  # 부동소수 표현 경계(Godot 와 같은 식)
