"""pytest 공용 픽스처. 임시 SQLite DB + 트랙 스냅샷을 로드한 TestClient 를 제공한다."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

# server/app/tracks 스냅샷(공식 트랙 5종). 테스트는 이 실제 파일들로 시드한다.
TRACKS_DIR = Path(__file__).resolve().parent.parent / "app" / "tracks"


def make_settings(tmp_path: Path, **overrides: object) -> Settings:
    """테스트용 격리 설정: 임시 DB + 실제 트랙 스냅샷 + 높은 레이트리밋 기본값."""
    db_path = tmp_path / "test.db"
    kwargs: dict[str, object] = {
        "db_url": f"sqlite:///{db_path}",
        "tracks_dir": TRACKS_DIR,
        "rate_limit_per_minute": 100000,  # 기본은 사실상 무제한(레이트리밋 테스트만 낮춤)
        "cors_origins": "*",
    }
    kwargs.update(overrides)
    return Settings(**kwargs)


@pytest.fixture
def client(tmp_path: Path):
    """기본 테스트 클라이언트(격리 DB, 사실상 무제한 레이트리밋)."""
    app = create_app(make_settings(tmp_path))
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def make_client(tmp_path: Path) -> Callable[..., TestClient]:
    """설정을 덮어써 클라이언트를 만드는 팩토리(레이트리밋 등 커스터마이즈용)."""

    def _make(**overrides: object) -> TestClient:
        app = create_app(make_settings(tmp_path, **overrides))
        return TestClient(app)

    return _make


@pytest.fixture
def cotton_checksum(client: TestClient) -> str:
    """시드된 cotton_01 트랙의 실제 체크섬(파일 바이트 SHA-256)."""
    resp = client.get("/api/tracks")
    assert resp.status_code == 200
    tracks = {t["id"]: t for t in resp.json()}
    return tracks["cotton_01"]["checksum"]


@pytest.fixture
def make_payload() -> Callable[..., dict]:
    """유효한 POST /api/runs 바디 생성기. overrides 로 개별 필드를 바꾼다."""

    def _make(checksum: str, **overrides: object) -> dict:
        payload: dict[str, object] = {
            "player_name": "player01",
            "track_id": "cotton_01",
            "difficulty": "normal",
            "time_ms": 30000,
            "penalty_ms": 0,
            "final_time_ms": 30000,
            "accuracy": 94.2,
            "cuts": 1,
            "off_seam_ms": 840,
            "game_version": "0.1.0",
            "track_checksum": checksum,
        }
        payload.update(overrides)
        return payload

    return _make
