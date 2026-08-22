"""레이트리밋 테스트 (기획서 §18: IP당 분당 N회, 인메모리). 초과 시 429."""

from __future__ import annotations


def _checksum(test_client) -> str:
    tracks = {t["id"]: t for t in test_client.get("/api/tracks").json()}
    return tracks["cotton_01"]["checksum"]


def test_rate_limit_blocks_after_threshold(make_client, make_payload):
    client = make_client(rate_limit_per_minute=3)
    checksum = _checksum(client)  # GET 은 레이트리밋 대상 아님.

    for i in range(3):
        resp = client.post(
            "/api/runs", json=make_payload(checksum, player_name=f"p{i}")
        )
        assert resp.status_code == 201, resp.text

    # 4번째 요청은 분당 한도(3) 초과 → 429.
    resp = client.post("/api/runs", json=make_payload(checksum, player_name="p4"))
    assert resp.status_code == 429


def test_rate_limit_reads_not_limited(make_client):
    client = make_client(rate_limit_per_minute=1)
    # 읽기 엔드포인트는 몇 번을 호출해도 제한되지 않는다.
    for _ in range(5):
        assert client.get("/api/tracks").status_code == 200
        assert client.get(
            "/api/leaderboard", params={"track_id": "cotton_01"}
        ).status_code == 200
