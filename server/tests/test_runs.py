"""POST /api/runs 정상 제출 + GET /api/runs/{run_id} 테스트."""

from __future__ import annotations


def test_submit_valid_run(client, cotton_checksum, make_payload):
    resp = client.post("/api/runs", json=make_payload(cotton_checksum))
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert isinstance(body["run_id"], int)
    assert body["verification_status"] == "unverified"
    assert body["rank"] == 1  # 첫 기록이므로 1위


def test_get_run_detail(client, cotton_checksum, make_payload):
    submit = client.post("/api/runs", json=make_payload(cotton_checksum))
    run_id = submit.json()["run_id"]

    resp = client.get(f"/api/runs/{run_id}")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["run_id"] == run_id
    assert body["player_name"] == "player01"
    assert body["track_id"] == "cotton_01"
    assert body["final_time_ms"] == 30000
    assert body["verification_status"] == "unverified"
    assert body["replay_hash"] is None
    assert body["created_at"]


def test_get_run_not_found(client):
    resp = client.get("/api/runs/999999")
    assert resp.status_code == 404


def test_submit_accepts_optional_replay_hash(client, cotton_checksum, make_payload):
    replay = "sha256:" + "a" * 64
    resp = client.post(
        "/api/runs", json=make_payload(cotton_checksum, replay_hash=replay)
    )
    assert resp.status_code == 201, resp.text
    run_id = resp.json()["run_id"]
    detail = client.get(f"/api/runs/{run_id}").json()
    assert detail["replay_hash"] == replay


def test_player_name_leading_trailing_space_normalized(
    client, cotton_checksum, make_payload
):
    resp = client.post(
        "/api/runs", json=make_payload(cotton_checksum, player_name="  neo  ")
    )
    assert resp.status_code == 201, resp.text
    run_id = resp.json()["run_id"]
    detail = client.get(f"/api/runs/{run_id}").json()
    assert detail["player_name"] == "neo"  # 앞뒤 공백 정규화


def test_player_name_unicode_allowed(client, cotton_checksum, make_payload):
    resp = client.post(
        "/api/runs", json=make_payload(cotton_checksum, player_name="바느질왕")
    )
    assert resp.status_code == 201, resp.text
