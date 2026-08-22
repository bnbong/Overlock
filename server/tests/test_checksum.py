"""체크섬 계약 테스트: 서버 체크섬 == 트랙 JSON 파일 원본 바이트의 SHA-256.

이 계약이 깨지면 클라이언트가 계산한 체크섬과 서버 값이 어긋나 정상 제출이 거부된다.
클라이언트 워커는 자신이 번들한 동일 파일 바이트에 같은 계산을 적용해야 한다.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from app.seed import compute_file_checksum, compute_min_final_time_ms

TRACKS_DIR = Path(__file__).resolve().parent.parent / "app" / "tracks"


def test_server_checksum_matches_raw_file_bytes(client):
    resp = client.get("/api/tracks")
    served = {t["id"]: t["checksum"] for t in resp.json()}
    for track_id, checksum in served.items():
        path = TRACKS_DIR / f"{track_id}.json"
        expected = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
        assert checksum == expected, f"{track_id} 체크섬 불일치"


def test_compute_file_checksum_format():
    path = TRACKS_DIR / "cotton_01.json"
    value = compute_file_checksum(path)
    assert value.startswith("sha256:")
    assert len(value) == len("sha256:") + 64
    # 대소문자: 소문자 hex.
    assert value[len("sha256:") :].islower()


def test_physical_floor_formula():
    # (length / max_speed) * 1000 을 floor. cotton_01 length=3206, max=300 → 10686.
    assert compute_min_final_time_ms(3206, 300.0) == 10686
    assert compute_min_final_time_ms(0, 300.0) == 0
    assert compute_min_final_time_ms(3000, 0) == 0  # 0 나눗셈 방지
