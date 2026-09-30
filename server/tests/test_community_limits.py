"""공유 허브 본문 상한(413)과 레이트리밋(429) 테스트.

- 413: 선언 Content-Length 초과, chunked(길이 없음), 거짓 Content-Length 모두 실제 바이트로 차단.
- 경로별 상한: /api/runs 는 기존 max_body_bytes(16KB), 허브는 community_max_body_bytes.
- 429: 게시(분당·일일)·조회·삭제 버킷이 서로, 그리고 기록 제출 버킷과 독립.
"""

from __future__ import annotations

import asyncio
import json

from app.main import ContentLengthLimitMiddleware
from app.ratelimit import RateLimiter

URL = "/api/community/tracks"


def _checksum(test_client) -> str:
    tracks = {t["id"]: t for t in test_client.get("/api/tracks").json()}
    return tracks["cotton_01"]["checksum"]


# ---------------------------------------------------------------------------
# 413
# ---------------------------------------------------------------------------
def test_declared_content_length_over_community_limit(make_client, make_community_payload):
    client = make_client(community_max_body_bytes=1000)
    raw = json.dumps(make_community_payload()).encode()
    assert len(raw) > 1000
    resp = client.post(URL, content=raw, headers={"Content-Type": "application/json"})
    assert resp.status_code == 413
    assert "너무 큽니다" in resp.json()["detail"]


def test_chunked_body_over_limit_413(make_client, make_community_payload):
    client = make_client(community_max_body_bytes=1000)
    raw = json.dumps(make_community_payload()).encode()

    def gen():
        for i in range(0, len(raw), 500):
            yield raw[i : i + 500]

    resp = client.post(URL, content=gen(), headers={"Content-Type": "application/json"})
    assert resp.status_code == 413, resp.text


def test_chunked_body_under_limit_is_replayed(make_client, make_community_payload):
    client = make_client()
    raw = json.dumps(make_community_payload()).encode()

    def gen():
        for i in range(0, len(raw), 700):
            yield raw[i : i + 700]

    resp = client.post(URL, content=gen(), headers={"Content-Type": "application/json"})
    assert resp.status_code == 201, resp.text


def _run_asgi(app, scope, chunks):
    """ASGI 앱을 직접 호출한다(TestClient 가 만들 수 없는 거짓 Content-Length 재현용)."""
    messages = [
        {"type": "http.request", "body": c, "more_body": i < len(chunks) - 1}
        for i, c in enumerate(chunks)
    ]
    sent: list[dict] = []
    reached = {"app": False, "body": b""}

    async def receive():
        if messages:
            return messages.pop(0)
        return {"type": "http.disconnect"}

    async def send(message):
        sent.append(message)

    async def inner(scope, receive, send):
        reached["app"] = True
        body = b""
        while True:
            m = await receive()
            body += m.get("body", b"")
            if not m.get("more_body"):
                break
        reached["body"] = body
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})

    mw = ContentLengthLimitMiddleware(
        inner, max_body_bytes=16, streamed_prefixes=(("/api/community/", 100),)
    )
    asyncio.run(mw(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    return status, reached


def _scope(path: str, headers: list[tuple[bytes, bytes]]):
    return {"type": "http", "method": "POST", "path": path, "headers": headers}


def test_false_content_length_counted_by_real_bytes():
    # 선언은 10 bytes 지만 실제로는 150 bytes → 누적 계수로 413.
    status, reached = _run_asgi(
        None, _scope("/api/community/tracks", [(b"content-length", b"10")]), [b"x" * 50] * 3
    )
    assert status == 413
    assert reached["app"] is False


def test_missing_content_length_counted():
    status, reached = _run_asgi(None, _scope("/api/community/tracks", []), [b"x" * 60, b"y" * 60])
    assert status == 413 and reached["app"] is False


def test_streamed_under_limit_replays_full_body():
    status, reached = _run_asgi(None, _scope("/api/community/tracks", []), [b"ab", b"cd", b"ef"])
    assert status == 200
    assert reached["body"] == b"abcdef"


def test_other_paths_keep_declared_only_small_limit():
    # 비허브 경로: 선언 길이만 검사(기존 동작). 16 bytes 초과 선언 → 413.
    status, _ = _run_asgi(None, _scope("/api/runs", [(b"content-length", b"17")]), [b"x" * 17])
    assert status == 413
    # 비허브 경로는 실제 바이트를 세지 않는다(기존 동작 보존, 프록시 제한 병행 전제).
    status, reached = _run_asgi(None, _scope("/api/runs", []), [b"x" * 40])
    assert status == 200 and reached["body"] == b"x" * 40


def test_runs_small_limit_not_raised(make_client, make_payload):
    # 허브 상한(1MiB)이 /api/runs 의 16KB 상한을 올리지 않는다.
    client = make_client()
    checksum = _checksum(client)
    payload = make_payload(checksum)
    payload["replay_hash"] = None
    raw = json.dumps(payload).encode() + b" " * (17 * 1024)
    resp = client.post("/api/runs", content=raw, headers={"Content-Type": "application/json"})
    assert resp.status_code == 413


def test_community_body_larger_than_runs_limit_accepted(make_client, make_community_payload):
    client = make_client()
    raw = json.dumps(make_community_payload(), indent=4).encode()
    raw += b" " * (40 * 1024)  # 16KB 보다 크지만 1MiB 보다 작다
    resp = client.post(URL, content=raw, headers={"Content-Type": "application/json"})
    assert resp.status_code == 201, resp.text


def test_413_on_community_carries_cors(make_client, make_community_payload):
    origin = "https://overlock.bnbong.com"
    client = make_client(community_max_body_bytes=100, cors_origins=origin)
    resp = client.post(URL, json=make_community_payload(), headers={"Origin": origin})
    assert resp.status_code == 413
    assert resp.headers.get("access-control-allow-origin") == origin


# ---------------------------------------------------------------------------
# 429
# ---------------------------------------------------------------------------
def test_post_per_minute_limit(make_client, make_community_payload):
    client = make_client(community_post_per_minute=3)
    for i in range(3):
        assert client.post(URL, json=make_community_payload(title=f"t{i}")).status_code == 201
    resp = client.post(URL, json=make_community_payload(title="t4"))
    assert resp.status_code == 429
    assert isinstance(resp.json()["detail"], str)


def test_post_daily_limit(make_client, make_community_payload):
    client = make_client(community_post_per_minute=100, community_post_per_day=2)
    for i in range(2):
        assert client.post(URL, json=make_community_payload(title=f"t{i}")).status_code == 201
    assert client.post(URL, json=make_community_payload(title="t3")).status_code == 429


def test_invalid_posts_also_count(make_client, make_community_payload):
    # 검증 실패 요청도 게시 버킷을 소모한다(무거운 기하 검증 반복 방어).
    client = make_client(community_post_per_minute=2)
    bad = make_community_payload(title="")
    assert client.post(URL, json=bad).status_code == 422
    assert client.post(URL, json=bad).status_code == 422
    assert client.post(URL, json=make_community_payload()).status_code == 429


def test_read_limit_shared_by_list_and_detail(make_client, make_community_payload):
    client = make_client(community_read_per_minute=3)
    created = client.post(URL, json=make_community_payload()).json()  # 게시는 조회 버킷과 별개
    assert client.get(URL).status_code == 200
    assert client.get(f"{URL}/{created['id']}").status_code == 200
    assert client.get(URL, params={"q": "x"}).status_code == 200
    assert client.get(URL).status_code == 429
    assert client.get(f"{URL}/{created['id']}").status_code == 429


def test_delete_limit(make_client, make_community_payload):
    client = make_client(community_delete_per_minute=2)
    created = client.post(URL, json=make_community_payload()).json()
    url = f"{URL}/{created['id']}"
    for _ in range(2):
        assert client.delete(url, headers={"Authorization": "Bearer guess"}).status_code == 403
    # 한도 초과 뒤에는 올바른 토큰이어도 429(추측 시도 차단).
    r = client.delete(url, headers={"Authorization": f"Bearer {created['delete_token']}"})
    assert r.status_code == 429


def test_community_buckets_independent_from_runs(make_client, make_payload, make_community_payload):
    client = make_client(rate_limit_per_minute=1, community_post_per_minute=1, community_read_per_minute=1)
    checksum = _checksum(client)
    # 기록 제출 버킷 소진
    assert client.post("/api/runs", json=make_payload(checksum)).status_code == 201
    assert client.post("/api/runs", json=make_payload(checksum, player_name="p2")).status_code == 429
    # 허브 게시·조회는 영향 없음
    assert client.post(URL, json=make_community_payload()).status_code == 201
    assert client.get(URL).status_code == 200
    # 허브 버킷 소진 → 허브만 429, 기록 조회/제출 버킷은 별개
    assert client.post(URL, json=make_community_payload()).status_code == 429
    assert client.get(URL).status_code == 429
    assert client.get("/api/tracks").status_code == 200


def test_community_limit_uses_trusted_proxy_ip(make_client, make_community_payload):
    client = make_client(community_post_per_minute=1, trust_forwarded_for=True, trusted_proxy_hops=1)

    def post(xff: str):
        return client.post(URL, json=make_community_payload(), headers={"X-Forwarded-For": xff})

    assert post("10.0.0.1, 203.0.113.1").status_code == 201
    assert post("10.9.9.9, 203.0.113.1").status_code == 429  # 선두값 조작으로 버킷 회전 불가
    assert post("10.0.0.1, 203.0.113.2").status_code == 201  # 다른 실제 IP → 별도 버킷


# ---------------------------------------------------------------------------
# RateLimiter 윈도 길이 확장
# ---------------------------------------------------------------------------
def test_ratelimiter_custom_window():
    limiter = RateLimiter(2, window_seconds=86400.0)
    assert limiter.allow("ip", now=0.0)
    assert limiter.allow("ip", now=100.0)
    assert not limiter.allow("ip", now=3600.0)  # 분 단위로는 풀렸지만 일 윈도 안
    assert limiter.allow("ip", now=86400.5)  # 첫 요청이 윈도 밖으로 나감


def test_ratelimiter_default_window_unchanged():
    limiter = RateLimiter(1)
    assert limiter.window_seconds == 60.0
    assert limiter.allow("a", now=0.0)
    assert not limiter.allow("a", now=59.0)
    assert limiter.allow("a", now=60.5)


def test_ratelimiter_sweep_keeps_decisions():
    limiter = RateLimiter(1)
    for i in range(3000):
        limiter.allow(f"ip{i}", now=float(i))
    # 오래된 키는 정리되지만 활성 키의 판정은 유지된다.
    assert len(limiter._hits) < 3000
    assert not limiter.allow("ip2999", now=2999.5)
