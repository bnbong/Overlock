"""체크섬 계약 테스트: 서버 체크섬 == 트랙 JSON 파일 원본 바이트의 SHA-256.

이 계약이 깨지면 클라이언트가 계산한 체크섬과 서버 값이 어긋나 정상 제출이 거부된다.
클라이언트 워커는 자신이 번들한 동일 파일 바이트에 같은 계산을 적용해야 한다.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from app.models import Track
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
    # floor((length / max_speed) * 1000 * safety_factor). cotton_01 length=3206, max=300.
    # 안전계수 0.75(코너컷 보정, §18) → 8015, 계수 1.0(=기본) → 10686.
    assert compute_min_final_time_ms(3206, 300.0, 0.75) == 8015
    assert compute_min_final_time_ms(3206, 300.0, 1.0) == 10686
    assert compute_min_final_time_ms(3206, 300.0) == 10686  # 기본 계수 1.0
    assert compute_min_final_time_ms(0, 300.0) == 0
    assert compute_min_final_time_ms(3000, 0) == 0  # 0 나눗셈 방지


# 전 트랙 물리 하한 회귀(§18). 안전계수 0.75(client 기본 설정)로 시드된 각 트랙의
# min_final_time_ms 가 표와 일치해야 한다. 트랙 길이나 계수가 바뀌면 여기서 잡힌다.
# NOTE: cat_01 은 수학적 정확값이 8095 지만, 지정 공식의 부동소수점 연산
# ((3238/300.0)*1000.0*0.75 = 8094.999999999999) 을 floor 하면 8094 다(코드 실제값).
# v1.1.0: 트랙 6~10(spool/basin/selvedge/harbor/summit)은 코너 완화를 위해 균등
# 스케일 업(길이 +20~40%)되어 하한이 상향됐고, 장거리 신규 5종(tee/button/bowtie/
# sock/ridge)이 추가돼 표는 15종이다. 각 값 = floor((length/300.0)*1000.0*0.75).
_EXPECTED_MIN_TIME_075 = {
    "cotton_01": 8015,
    "heart_01": 7242,
    "cat_01": 8094,
    "tee_01": 14752,
    "button_01": 14762,
    "star_01": 8862,
    "fish_01": 8360,
    "spool_01": 11242,
    "basin_01": 10897,
    "selvedge_01": 11707,
    "bowtie_01": 14757,
    "sock_01": 15502,
    "harbor_01": 9335,
    "summit_01": 8572,
    "ridge_01": 18242,
}


@pytest.mark.parametrize("track_id,expected", list(_EXPECTED_MIN_TIME_075.items()))
def test_seeded_min_final_time_regression(client, track_id, expected):
    session = client.app.state.sessionmaker()
    try:
        track = session.get(Track, track_id)
        assert track is not None, f"{track_id} 미시드"
        assert track.min_final_time_ms == expected, track_id
    finally:
        session.close()
