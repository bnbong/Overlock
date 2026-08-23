"""레이트리밋 X-Forwarded-For 처리 테스트 (B-4 DoS 방어).

신뢰 프록시 뒤 배포를 전제로 XFF 는 "끝에서 trusted_proxy_hops 번째" 값을 실제
클라이언트 IP 로 쓴다. 클라이언트가 조작할 수 있는 선두(왼쪽) 값을 바꿔 레이트리밋
버킷을 회전시킬 수 없어야 한다.
"""

from __future__ import annotations


def _checksum(test_client) -> str:
    tracks = {t["id"]: t for t in test_client.get("/api/tracks").json()}
    return tracks["cotton_01"]["checksum"]


def test_spoofed_leading_xff_cannot_rotate_bucket(make_client, make_payload):
    # 신뢰 홉 1: 신뢰 프록시가 XFF 끝에 실제 클라이언트 IP 를 넣는다고 본다.
    client = make_client(
        rate_limit_per_minute=3,
        trust_forwarded_for=True,
        trusted_proxy_hops=1,
    )
    checksum = _checksum(client)

    # 매 요청 선두값(공격자가 조작)은 다르지만 끝값(신뢰 프록시가 넣은 실제 IP)은 동일.
    def _post(i: int):
        return client.post(
            "/api/runs",
            json=make_payload(checksum, player_name=f"p{i}"),
            headers={"X-Forwarded-For": f"10.0.0.{i}, 203.0.113.7"},
        )

    for i in range(3):
        assert _post(i).status_code == 201, _post

    # 선두값을 바꿔도 끝값이 같아 같은 버킷 → 한도(3) 초과로 429.
    assert _post(99).status_code == 429


def test_distinct_real_clients_get_separate_buckets(make_client, make_payload):
    # 끝값(실제 클라이언트 IP)이 다르면 서로 다른 버킷이라 각자 한도를 따로 갖는다.
    client = make_client(
        rate_limit_per_minute=1,
        trust_forwarded_for=True,
        trusted_proxy_hops=1,
    )
    checksum = _checksum(client)

    r1 = client.post(
        "/api/runs",
        json=make_payload(checksum, player_name="a"),
        headers={"X-Forwarded-For": "10.0.0.1, 203.0.113.1"},
    )
    r2 = client.post(
        "/api/runs",
        json=make_payload(checksum, player_name="b"),
        headers={"X-Forwarded-For": "10.0.0.1, 203.0.113.2"},
    )
    assert r1.status_code == 201, r1.text
    assert r2.status_code == 201, r2.text  # 다른 실제 IP → 별도 버킷


def test_multi_hop_reads_from_end(make_client, make_payload):
    # 신뢰 홉 2: 끝에서 2번째 값이 실제 클라이언트 IP. 그 앞은 조작 가능 영역.
    client = make_client(
        rate_limit_per_minute=2,
        trust_forwarded_for=True,
        trusted_proxy_hops=2,
    )
    checksum = _checksum(client)

    def _post(i: int):
        # 실제 IP(끝에서 2번째)=198.51.100.5 고정, 그 뒤 신뢰 프록시 홉 1개, 선두는 조작.
        return client.post(
            "/api/runs",
            json=make_payload(checksum, player_name=f"p{i}"),
            headers={"X-Forwarded-For": f"1.2.3.{i}, 198.51.100.5, 203.0.113.9"},
        )

    for i in range(2):
        assert _post(i).status_code == 201
    assert _post(99).status_code == 429
