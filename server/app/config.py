"""환경변수/기본값 기반 서버 설정 (기획서 §12: SQLite 경로·호스트·포트 config화).

모든 값은 ``OVERLOCK_`` 접두 환경변수로 덮어쓸 수 있다. 예) ``OVERLOCK_PORT=9000``.
배포 시에는 DB 경로·CORS 허용 도메인·레이트리밋만 조정하면 된다.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# server/app/config.py → server/  (SQLite 기본 경로·트랙 스냅샷 기준 디렉토리)
_SERVER_ROOT: Path = Path(__file__).resolve().parent.parent
_APP_DIR: Path = Path(__file__).resolve().parent


class Settings(BaseSettings):
    """서버 런타임 설정.

    - ``db_url``: SQLAlchemy URL. 기본은 server/overlock.db SQLite 파일.
      PostgreSQL 전환 시 ``postgresql+psycopg://user:pw@host/db`` 형태로 교체(§12).
    - ``cors_origins``: 쉼표 구분 도메인 목록. ``*`` 는 전체 허용(오픈소스 웹 클라이언트).
    - ``rate_limit_per_minute``: POST /api/runs 의 IP당 분당 허용 횟수(인메모리).
    - ``trust_forwarded_for``: 리버스 프록시(nginx) 뒤에서 실제 IP를 쓰려면 True.
    """

    model_config = SettingsConfigDict(
        env_prefix="OVERLOCK_",
        env_file=".env",
        extra="ignore",
    )

    db_url: str = Field(default=f"sqlite:///{_SERVER_ROOT / 'overlock.db'}")
    host: str = "0.0.0.0"
    port: int = 8000

    cors_origins: str = "*"
    rate_limit_per_minute: int = 60
    trust_forwarded_for: bool = False

    # 공식 트랙 스냅샷 디렉토리(game/tracks/official 에서 복사해 둔 것).
    tracks_dir: Path = _APP_DIR / "tracks"

    # 물리 하한 계산용 최고 속도(px/s). 기획서 §7.2 Overlock 단계 = 300.
    max_speed_px_s: float = 300.0

    @field_validator("tracks_dir", mode="before")
    @classmethod
    def _expand_tracks_dir(cls, value: object) -> object:
        if isinstance(value, str):
            return Path(value)
        return value

    def cors_origin_list(self) -> list[str]:
        """CORS 허용 오리진 목록. ``*`` 단일이면 전체 허용."""
        raw = [o.strip() for o in self.cors_origins.split(",") if o.strip()]
        return raw or ["*"]


@lru_cache
def get_settings() -> Settings:
    """프로세스 전역 기본 설정(환경변수 반영). 테스트는 별도 Settings를 주입한다."""
    return Settings()
