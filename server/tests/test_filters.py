"""비정상 기록 필터 거부 케이스 (기획서 §18). 모든 거부는 HTTP 422."""

from __future__ import annotations

import pytest


def test_reject_unregistered_track(client, cotton_checksum, make_payload):
    # 미등록 track_id → 422 (체크섬 형식은 유효해도 트랙이 없으면 거부).
    resp = client.post(
        "/api/runs", json=make_payload(cotton_checksum, track_id="ghost_01")
    )
    assert resp.status_code == 422


def test_reject_checksum_mismatch(client, make_payload):
    wrong = "sha256:" + "0" * 64  # 형식은 유효하지만 등록 값과 다름.
    resp = client.post("/api/runs", json=make_payload(wrong))
    assert resp.status_code == 422


def test_reject_below_physical_floor(client, cotton_checksum, make_payload):
    # cotton_01 길이 3206px / 300px/s ≈ 10.686s. 5s 기록은 물리적으로 불가능.
    resp = client.post(
        "/api/runs",
        json=make_payload(
            cotton_checksum, time_ms=5000, penalty_ms=0, final_time_ms=5000
        ),
    )
    assert resp.status_code == 422
    assert "물리" in resp.json()["detail"] or "min=" in resp.json()["detail"]


def test_accept_just_above_physical_floor(client, cotton_checksum, make_payload):
    # 안전계수 적용 하한 위 기록은 허용되어야 한다.
    resp = client.post(
        "/api/runs",
        json=make_payload(
            cotton_checksum, time_ms=10700, penalty_ms=0, final_time_ms=10700
        ),
    )
    assert resp.status_code == 201, resp.text


def test_accept_between_old_and_new_floor(client, cotton_checksum, make_payload):
    # 회귀 핵심(오거부 버그 수정): cotton_01 하한이 낮아졌다.
    # 구 하한(10686)에서는 422 로 거부됐을 10600ms 정당 기록이 이제 201 로 수용돼야 한다.
    resp = client.post(
        "/api/runs",
        json=make_payload(
            cotton_checksum, time_ms=10600, penalty_ms=0, final_time_ms=10600
        ),
    )
    assert resp.status_code == 201, resp.text


def test_reject_far_below_physical_floor(client, cotton_checksum, make_payload):
    # 하한(8015ms)보다 한참 빠른 1000ms 는 여전히 물리적으로 불가능 → 422.
    resp = client.post(
        "/api/runs",
        json=make_payload(
            cotton_checksum, time_ms=1000, penalty_ms=0, final_time_ms=1000
        ),
    )
    assert resp.status_code == 422
    assert "물리" in resp.json()["detail"] or "min=" in resp.json()["detail"]


@pytest.mark.parametrize("accuracy", [-0.1, 100.1, 150.0])
def test_reject_accuracy_out_of_range(client, cotton_checksum, make_payload, accuracy):
    resp = client.post(
        "/api/runs", json=make_payload(cotton_checksum, accuracy=accuracy)
    )
    assert resp.status_code == 422


def test_reject_negative_cuts(client, cotton_checksum, make_payload):
    resp = client.post("/api/runs", json=make_payload(cotton_checksum, cuts=-1))
    assert resp.status_code == 422


def test_reject_penalty_inconsistency(client, cotton_checksum, make_payload):
    # final != time + penalty → 422.
    resp = client.post(
        "/api/runs",
        json=make_payload(
            cotton_checksum, time_ms=30000, penalty_ms=1000, final_time_ms=30000
        ),
    )
    assert resp.status_code == 422


@pytest.mark.parametrize(
    "name",
    [
        "",  # 빈 문자열
        "   ",  # 공백만
        "a" * 17,  # 16자 초과
        "ab\x00cd",  # 제어 문자
        "line\nbreak",  # 개행(제어 문자)
    ],
)
def test_reject_invalid_player_name(client, cotton_checksum, make_payload, name):
    resp = client.post(
        "/api/runs", json=make_payload(cotton_checksum, player_name=name)
    )
    assert resp.status_code == 422


@pytest.mark.parametrize("version", ["abc", "1.0", "v1.0.0", "1..0", ""])
def test_reject_invalid_game_version(client, cotton_checksum, make_payload, version):
    resp = client.post(
        "/api/runs", json=make_payload(cotton_checksum, game_version=version)
    )
    assert resp.status_code == 422


@pytest.mark.parametrize("checksum", ["notasha256", "sha256:xyz", "sha256:" + "a" * 63])
def test_reject_malformed_checksum(client, make_payload, checksum):
    resp = client.post("/api/runs", json=make_payload(checksum))
    assert resp.status_code == 422


def test_reject_negative_time(client, cotton_checksum, make_payload):
    resp = client.post(
        "/api/runs",
        json=make_payload(
            cotton_checksum, time_ms=-1, penalty_ms=0, final_time_ms=-1
        ),
    )
    assert resp.status_code == 422
