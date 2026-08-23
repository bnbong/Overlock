"""요청 바디 크기 상한 테스트 (B-1 DoS 방어).

Content-Length 가 config.max_body_bytes 를 넘으면 본문을 읽기 전에 413 으로 차단한다.
413 응답에도 CORS 헤더가 붙어야 하므로(CORS 미들웨어가 바깥쪽) 그 점도 검증한다.
"""

from __future__ import annotations

PROD_ORIGIN = "https://overlock.bnbong.com"


def _checksum(test_client) -> str:
    tracks = {t["id"]: t for t in test_client.get("/api/tracks").json()}
    return tracks["cotton_01"]["checksum"]


def test_oversized_body_returns_413(make_client, make_payload):
    # max_body_bytes 를 아주 작게 두면 정상 페이로드(수백 바이트)도 상한을 넘는다.
    client = make_client(max_body_bytes=50)
    checksum = _checksum(client)
    resp = client.post("/api/runs", json=make_payload(checksum))
    assert resp.status_code == 413, resp.text
    assert "너무 큽니다" in resp.json()["detail"]


def test_413_carries_cors_header(make_client, make_payload):
    # CORS 미들웨어가 바깥쪽이므로 413(내부 미들웨어 생성)에도 CORS 헤더가 붙어야 한다.
    client = make_client(max_body_bytes=50, cors_origins=PROD_ORIGIN)
    checksum = _checksum(client)
    resp = client.post(
        "/api/runs",
        json=make_payload(checksum),
        headers={"Origin": PROD_ORIGIN},
    )
    assert resp.status_code == 413
    assert resp.headers.get("access-control-allow-origin") == PROD_ORIGIN


def test_normal_body_under_limit_ok(make_client, make_payload):
    # 기본 16KB 상한에서는 정상 제출이 통과한다(413 이 아무 요청이나 막지 않는다).
    client = make_client()
    checksum = _checksum(client)
    resp = client.post("/api/runs", json=make_payload(checksum))
    assert resp.status_code == 201, resp.text


def test_get_request_not_affected_by_limit(make_client):
    # 본문 없는 GET 은 상한을 극단적으로 낮춰도 영향받지 않는다.
    client = make_client(max_body_bytes=1)
    assert client.get("/api/health").status_code == 200
    assert client.get("/api/tracks").status_code == 200


def test_long_player_name_rejected_at_parse(make_client, make_payload):
    # player_name Field(max_length=64) 파싱 단계 조기 차단(거대 문자열 방어) → 422.
    client = make_client()
    checksum = _checksum(client)
    resp = client.post(
        "/api/runs",
        json=make_payload(checksum, player_name="x" * 100),
    )
    assert resp.status_code == 422
