"""GET /api/health, GET /api/tracks 테스트."""

from __future__ import annotations


def test_health(client):
    resp = client.get("/api/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert isinstance(body["version"], str) and body["version"]


def test_tracks_lists_all_official(client):
    resp = client.get("/api/tracks")
    assert resp.status_code == 200
    tracks = resp.json()
    ids = {t["id"] for t in tracks}
    # 공식 트랙 15종(기존 5 + F1 형상 참고 5 + v1.1.0 장거리 신규 5)이 모두 시드되어야 한다.
    assert ids == {
        "cotton_01", "heart_01", "cat_01", "star_01", "fish_01",
        "spool_01", "basin_01", "selvedge_01", "harbor_01", "summit_01",
        "tee_01", "button_01", "bowtie_01", "sock_01", "ridge_01",
    }
    for track in tracks:
        assert track["checksum"].startswith("sha256:")
        assert len(track["checksum"]) == len("sha256:") + 64
        assert track["name"]
        assert track["difficulty"]
