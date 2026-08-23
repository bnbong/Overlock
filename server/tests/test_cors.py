"""CORS 미들웨어 테스트 (itch.io 임베드 오리진 허용, 무관 오리진 거부).

프로덕션과 동일하게 정확-일치 오리진을 프로덕션 도메인으로 좁힌 뒤(allow_all 비활성),
정규식(*.itch.zone)으로 itch.io 임베드 오리진이 허용되는지 검증한다.
"""

from __future__ import annotations

# itch.io 는 게임을 *.itch.zone iframe 오리진에서 실행한다(서브도메인은 게임마다 다름).
ITCH_ORIGIN = "https://html-classic.itch.zone"
ITCH_ORIGIN_ALT = "https://random-game-123.itch.zone"
PROD_ORIGIN = "https://overlock.bnbong.com"
UNRELATED_ORIGIN = "https://evil.example.com"

# allow_all(=cors_origins="*") 을 끄고 정규식·정확일치 경로를 실제로 태우기 위한 설정.
_STRICT_ORIGINS = {"cors_origins": PROD_ORIGIN}


def test_preflight_allows_itch_origin(make_client):
    """프리플라이트(OPTIONS): itch.zone 서브도메인이 Access-Control-Allow-Origin 으로 반사된다."""
    client = make_client(**_STRICT_ORIGINS)
    resp = client.options(
        "/api/leaderboard",
        headers={
            "Origin": ITCH_ORIGIN,
            "Access-Control-Request-Method": "GET",
        },
    )
    assert resp.status_code == 200
    assert resp.headers.get("access-control-allow-origin") == ITCH_ORIGIN


def test_preflight_allows_other_itch_subdomain(make_client):
    """프리플라이트: itch.zone 의 임의 서브도메인도 정규식으로 허용된다."""
    client = make_client(**_STRICT_ORIGINS)
    resp = client.options(
        "/api/leaderboard",
        headers={
            "Origin": ITCH_ORIGIN_ALT,
            "Access-Control-Request-Method": "GET",
        },
    )
    assert resp.status_code == 200
    assert resp.headers.get("access-control-allow-origin") == ITCH_ORIGIN_ALT


def test_actual_request_allows_itch_origin(make_client):
    """실요청(GET): itch.zone 오리진에 Access-Control-Allow-Origin 이 붙는다."""
    client = make_client(**_STRICT_ORIGINS)
    resp = client.get("/api/health", headers={"Origin": ITCH_ORIGIN})
    assert resp.status_code == 200
    assert resp.headers.get("access-control-allow-origin") == ITCH_ORIGIN


def test_actual_request_allows_prod_origin(make_client):
    """실요청: 프로덕션 웹 도메인(정확 일치)도 허용된다."""
    client = make_client(**_STRICT_ORIGINS)
    resp = client.get("/api/health", headers={"Origin": PROD_ORIGIN})
    assert resp.status_code == 200
    assert resp.headers.get("access-control-allow-origin") == PROD_ORIGIN


def test_preflight_rejects_unrelated_origin(make_client):
    """프리플라이트: 무관 오리진은 Access-Control-Allow-Origin 을 돌려받지 못한다."""
    client = make_client(**_STRICT_ORIGINS)
    resp = client.options(
        "/api/leaderboard",
        headers={
            "Origin": UNRELATED_ORIGIN,
            "Access-Control-Request-Method": "GET",
        },
    )
    assert "access-control-allow-origin" not in resp.headers


def test_actual_request_rejects_unrelated_origin(make_client):
    """실요청: 무관 오리진에는 Access-Control-Allow-Origin 헤더가 붙지 않는다(응답 자체는 정상)."""
    client = make_client(**_STRICT_ORIGINS)
    resp = client.get("/api/health", headers={"Origin": UNRELATED_ORIGIN})
    assert resp.status_code == 200
    assert "access-control-allow-origin" not in resp.headers


def test_itch_origin_spoof_rejected(make_client):
    """정규식이 itch.zone 을 접미로만 갖는 사칭 도메인을 거부한다(fullmatch 앵커 확인)."""
    client = make_client(**_STRICT_ORIGINS)
    resp = client.get(
        "/api/health",
        headers={"Origin": "https://html-classic.itch.zone.evil.com"},
    )
    assert resp.status_code == 200
    assert "access-control-allow-origin" not in resp.headers
