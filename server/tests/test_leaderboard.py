"""GET /api/leaderboard 정렬(§14.1) + 플레이어당 최고 1건 + rank + 페이지네이션."""

from __future__ import annotations


def _submit(client, checksum, make_payload, **overrides):
    resp = client.post("/api/runs", json=make_payload(checksum, **overrides))
    assert resp.status_code == 201, resp.text
    return resp.json()


def test_sort_by_final_time(client, cotton_checksum, make_payload):
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
    # 동일 final_time → accuracy 내림차순, 다음 cuts 오름차순(§14.1).
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
