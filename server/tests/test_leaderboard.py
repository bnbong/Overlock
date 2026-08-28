"""GET /api/leaderboard 정렬(§14.1: 등급 우선 → 시간 차선) + 플레이어당 최고 1건 +
rank + 페이지네이션.

v1.1.0 정렬 규칙: 재봉 등급 티어 내림차순(S>A>B>C>D) → 같은 등급 안에서 final_time_ms
오름차순 → 이하 기존 타이브레이커(accuracy↓, cuts↑, off_seam↑, created_at↑, id↑).
등급은 app/grade.py 가 accuracy·perfect_rate·cuts 에서 클라와 동일 공식으로 유도한다.
"""

from __future__ import annotations


def _submit(client, checksum, make_payload, **overrides):
    resp = client.post("/api/runs", json=make_payload(checksum, **overrides))
    assert resp.status_code == 201, resp.text
    return resp.json()


# 등급을 명시적으로 만들기 위한 메트릭 프리셋(app/grade.py 공식: acc*0.6+pr*0.4-cuts*5).
#   S = 100*0.6 + 100*0.4 - 0 = 100
#   A = 90*0.6  + 90*0.4  - 0 = 90
#   D = 60*0.6  + 0*0.4   - 0 = 36
_GRADE_S = {"accuracy": 100.0, "perfect_rate": 100.0, "cuts": 0}
_GRADE_A = {"accuracy": 90.0, "perfect_rate": 90.0, "cuts": 0}
_GRADE_D = {"accuracy": 60.0, "perfect_rate": 0.0, "cuts": 0}


def test_sort_by_final_time(client, cotton_checksum, make_payload):
    # 같은 등급 안에서의 시간 차선 정렬 검증. make_payload 기본 메트릭이 모두 동일해
    # 세 기록이 같은 등급 티어에 들어가므로, 정렬은 final_time 오름차순으로 결정된다.
    # 서로 다른 플레이어가 서로 다른 final_time 으로 제출.
    _submit(client, cotton_checksum, make_payload, player_name="slow",
            time_ms=50000, final_time_ms=50000)
    _submit(client, cotton_checksum, make_payload, player_name="fast",
            time_ms=20000, final_time_ms=20000)
    _submit(client, cotton_checksum, make_payload, player_name="mid",
            time_ms=35000, final_time_ms=35000)

    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    assert resp.status_code == 200
    entries = resp.json()["entries"]
    names = [e["player_name"] for e in entries]
    ranks = [e["rank"] for e in entries]
    assert names == ["fast", "mid", "slow"]
    assert ranks == [1, 2, 3]


def test_tiebreak_accuracy_then_cuts(client, cotton_checksum, make_payload):
    # 세 기록 모두 perfect_rate 기본(0.0)이라 등급 티어가 D 로 동일하고 final_time 도 같아,
    # 그다음 타이브레이커인 accuracy 내림차순 → cuts 오름차순으로 순위가 갈린다(§14.1).
    _submit(client, cotton_checksum, make_payload, player_name="lowacc",
            time_ms=30000, final_time_ms=30000, accuracy=80.0, cuts=0)
    _submit(client, cotton_checksum, make_payload, player_name="highacc",
            time_ms=30000, final_time_ms=30000, accuracy=95.0, cuts=2)
    _submit(client, cotton_checksum, make_payload, player_name="midacc",
            time_ms=30000, final_time_ms=30000, accuracy=95.0, cuts=0)

    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    names = [e["player_name"] for e in resp.json()["entries"]]
    # accuracy 95 두 명이 앞(그 중 cuts 적은 midacc 먼저), 그 뒤 accuracy 80.
    assert names == ["midacc", "highacc", "lowacc"]


def test_only_best_run_per_player(client, cotton_checksum, make_payload):
    # 같은 플레이어가 나쁜 기록 → 좋은 기록 순으로 제출.
    _submit(client, cotton_checksum, make_payload, player_name="repeat",
            time_ms=45000, final_time_ms=45000)
    _submit(client, cotton_checksum, make_payload, player_name="repeat",
            time_ms=25000, final_time_ms=25000)
    _submit(client, cotton_checksum, make_payload, player_name="other",
            time_ms=30000, final_time_ms=30000)

    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    body = resp.json()
    # repeat 은 최고 기록(25000) 1건만 노출, 총 2명.
    assert body["count"] == 2
    entries = body["entries"]
    assert len(entries) == 2
    repeat_entries = [e for e in entries if e["player_name"] == "repeat"]
    assert len(repeat_entries) == 1
    assert repeat_entries[0]["final_time_ms"] == 25000
    assert repeat_entries[0]["rank"] == 1  # 25000 < 30000


def test_submit_rank_reflects_position(client, cotton_checksum, make_payload):
    _submit(client, cotton_checksum, make_payload, player_name="a",
            time_ms=10000 + 10686, final_time_ms=10000 + 10686)  # 안전히 하한 위
    _submit(client, cotton_checksum, make_payload, player_name="b",
            time_ms=15000 + 10686, final_time_ms=15000 + 10686)
    # 새 플레이어 c 가 가장 빠른 기록 → rank 1 반환.
    body = _submit(client, cotton_checksum, make_payload, player_name="c",
                   time_ms=11000, final_time_ms=11000)
    assert body["rank"] == 1


def test_pagination(client, cotton_checksum, make_payload):
    for i in range(5):
        _submit(client, cotton_checksum, make_payload, player_name=f"p{i}",
                time_ms=20000 + i * 1000, final_time_ms=20000 + i * 1000)

    resp = client.get(
        "/api/leaderboard",
        params={"track_id": "cotton_01", "limit": 2, "offset": 2},
    )
    body = resp.json()
    assert body["count"] == 5
    assert body["limit"] == 2
    assert body["offset"] == 2
    entries = body["entries"]
    assert len(entries) == 2
    assert [e["player_name"] for e in entries] == ["p2", "p3"]
    assert [e["rank"] for e in entries] == [3, 4]  # 전역 순위(offset 반영)


def test_difficulty_filter(client, cotton_checksum, make_payload):
    _submit(client, cotton_checksum, make_payload, player_name="norm",
            difficulty="normal", time_ms=20000, final_time_ms=20000)
    _submit(client, cotton_checksum, make_payload, player_name="exp",
            difficulty="expert", time_ms=25000, final_time_ms=25000)

    resp = client.get(
        "/api/leaderboard",
        params={"track_id": "cotton_01", "difficulty": "expert"},
    )
    entries = resp.json()["entries"]
    assert [e["player_name"] for e in entries] == ["exp"]


def test_leaderboard_unregistered_track_404(client):
    resp = client.get("/api/leaderboard", params={"track_id": "nope_99"})
    assert resp.status_code == 404


def test_leaderboard_empty_for_registered_track(client):
    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["count"] == 0
    assert body["entries"] == []


def test_leaderboard_difficulty_length_capped(client):
    # B-5: GET difficulty 는 POST 와 동일하게 max_length=32. 초과 시 422.
    resp = client.get(
        "/api/leaderboard",
        params={"track_id": "cotton_01", "difficulty": "x" * 33},
    )
    assert resp.status_code == 422


# --- v1.1.0 등급 우선 정렬 (§14.1) ---


def test_grade_beats_faster_time(client, cotton_checksum, make_payload):
    # 등급 역전: 느리지만 높은 등급(S) 이 빠르지만 낮은 등급(D) 을 앞선다.
    # slow_s 는 25초·S, fast_d 는 12초·D 로, 시간만 보면 fast_d 가 빠르지만 등급이 우선한다.
    _submit(client, cotton_checksum, make_payload, player_name="fast_d",
            time_ms=12000, final_time_ms=12000, **_GRADE_D)
    _submit(client, cotton_checksum, make_payload, player_name="slow_s",
            time_ms=25000, final_time_ms=25000, **_GRADE_S)

    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    entries = resp.json()["entries"]
    assert [e["player_name"] for e in entries] == ["slow_s", "fast_d"]
    assert [e["grade"] for e in entries] == ["S", "D"]
    assert [e["rank"] for e in entries] == [1, 2]


def test_same_grade_orders_by_time(client, cotton_checksum, make_payload):
    # 동등급 안에서는 시간 차선: 두 S 등급 중 빠른 기록이 앞선다.
    _submit(client, cotton_checksum, make_payload, player_name="s_slow",
            time_ms=25000, final_time_ms=25000, **_GRADE_S)
    _submit(client, cotton_checksum, make_payload, player_name="s_fast",
            time_ms=20000, final_time_ms=20000, **_GRADE_S)

    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    entries = resp.json()["entries"]
    assert [e["player_name"] for e in entries] == ["s_fast", "s_slow"]
    assert all(e["grade"] == "S" for e in entries)
    assert [e["rank"] for e in entries] == [1, 2]


def test_grade_tiers_fully_ordered(client, cotton_checksum, make_payload):
    # S > A > D 전면 정렬: 시간을 일부러 등급과 역상관(S 가 가장 느림)으로 둬도 등급이 이긴다.
    _submit(client, cotton_checksum, make_payload, player_name="d_player",
            time_ms=13000, final_time_ms=13000, **_GRADE_D)
    _submit(client, cotton_checksum, make_payload, player_name="s_player",
            time_ms=30000, final_time_ms=30000, **_GRADE_S)
    _submit(client, cotton_checksum, make_payload, player_name="a_player",
            time_ms=21000, final_time_ms=21000, **_GRADE_A)

    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    entries = resp.json()["entries"]
    assert [e["player_name"] for e in entries] == ["s_player", "a_player", "d_player"]
    assert [e["grade"] for e in entries] == ["S", "A", "D"]


def test_player_best_selected_by_grade_first(client, cotton_checksum, make_payload):
    # 플레이어 베스트의 정의가 등급 우선으로 바뀜: 같은 플레이어가 S등급 25초와 A등급 20초를
    # 내면, 더 빠른 A(20초) 가 아니라 더 높은 등급 S(25초) 가 베스트로 단 1건 노출된다.
    _submit(client, cotton_checksum, make_payload, player_name="kim",
            time_ms=20000, final_time_ms=20000, **_GRADE_A)
    _submit(client, cotton_checksum, make_payload, player_name="kim",
            time_ms=25000, final_time_ms=25000, **_GRADE_S)

    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    body = resp.json()
    assert body["count"] == 1  # 서로 다른 플레이어 수(kim 1명)
    entries = body["entries"]
    assert len(entries) == 1
    assert entries[0]["player_name"] == "kim"
    assert entries[0]["grade"] == "S"
    assert entries[0]["final_time_ms"] == 25000  # 더 빠른 20000(A) 이 아니라 25000(S)


def test_submit_rank_reflects_grade_first(client, cotton_checksum, make_payload):
    # 제출 응답 rank 도 등급 우선 순위를 반영한다. 기존 1위가 빠른 D 여도, 새로 낸 느린 S 가
    # rank 1 을 받는다.
    _submit(client, cotton_checksum, make_payload, player_name="incumbent",
            time_ms=12000, final_time_ms=12000, **_GRADE_D)
    body = _submit(client, cotton_checksum, make_payload, player_name="challenger",
                   time_ms=28000, final_time_ms=28000, **_GRADE_S)
    assert body["rank"] == 1  # 느려도 S 등급이라 최상위


def test_leaderboard_entry_exposes_grade_and_perfect_rate(
    client, cotton_checksum, make_payload
):
    # 응답 스키마: 각 행에 grade(클라 표시용)와 perfect_rate 가 포함된다.
    _submit(client, cotton_checksum, make_payload, player_name="alpha",
            time_ms=20000, final_time_ms=20000, **_GRADE_A)
    resp = client.get("/api/leaderboard", params={"track_id": "cotton_01"})
    entry = resp.json()["entries"][0]
    assert entry["grade"] == "A"
    assert entry["perfect_rate"] == 90.0
