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
    - ``cors_origins``: 쉼표 구분 정확-일치 도메인 목록. ``*`` 는 전체 허용(오픈소스 웹 클라이언트).
    - ``cors_origin_regex``: 정확-일치 목록과 별개로 CORS 를 허용할 오리진 정규식.
      기본값은 itch.io 임베드 서브도메인(``*.itch.zone``) + 프로덕션 웹 도메인.
    - ``cors_allow_methods`` / ``cors_allow_headers``: 쉼표 구분 허용 메서드·헤더.
    - ``rate_limit_per_minute``: POST /api/runs 의 IP당 분당 허용 횟수(인메모리).
    - ``trust_forwarded_for``: 리버스 프록시(nginx) 뒤에서 실제 IP를 쓰려면 True.
    - ``trusted_proxy_hops``: 신뢰하는 프록시 홉 수. X-Forwarded-For 에서 끝에서
      이 수만큼 뒤의 값을 실제 클라이언트 IP 로 본다(선두값 조작 방어, §DoS).
    - ``max_body_bytes``: 요청 본문 Content-Length 상한(바이트). 초과 시 413 반환.
    - ``community_*``: 커스텀 트랙 공유 허브(/api/community/*) 전용 본문 상한과
      레이트리밋. 기록 제출(/api/runs)과 별도 버킷·별도 상한을 쓴다.
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
    # itch.io(*.itch.zone iframe 오리진) 처럼 same-origin 이 아닌 임베드 배포처를 위한 정규식.
    # cors_origins(정확 일치) 와 별개로 이 정규식에 매칭되는 오리진도 CORS 허용한다.
    # 기본값: itch.io 임베드 서브도메인 전체 + 프로덕션 웹 도메인.
    cors_origin_regex: str = r"^https://(?:[a-z0-9-]+\.itch\.zone|overlock\.bnbong\.com)$"
    # 허용 메서드·헤더(쉼표 구분). 인증 쿠키가 없어 credentials 는 항상 비활성
    # (allow_credentials=False, main.py). Authorization 헤더는 쿠키와 무관하게 동작한다.
    # 공유 허브 삭제(DELETE + Authorization: Bearer <삭제 토큰>)를 브라우저(웹 export)에서도
    # 호출할 수 있도록 DELETE 메서드와 Authorization 헤더를 기본 허용한다.
    cors_allow_methods: str = "GET,POST,DELETE"
    cors_allow_headers: str = "Content-Type,Accept,Authorization"
    rate_limit_per_minute: int = 60
    trust_forwarded_for: bool = False
    # 신뢰 프록시(리버스 프록시/CDN) 홉 수. X-Forwarded-For 는 각 프록시가 오른쪽에
    # 다운스트림 IP 를 덧붙이므로, 끝에서 이 수만큼 뒤의 값이 실제 클라이언트 IP 다.
    # 선두(왼쪽) 값은 클라이언트가 조작할 수 있어 신뢰하지 않는다(routes._client_key).
    # 기본 1: 신뢰 프록시 한 단(리버스 프록시가 클라이언트 IP 만 XFF 로 넘기는) 배포 전제.
    trusted_proxy_hops: int = 1
    # 요청 본문 크기 상한(바이트, 기본 16KB). Content-Length 가 이를 넘으면 413 으로
    # 조기 차단한다. 앱단은 Content-Length 만 보므로 chunked/거짓 길이는 못 막는다 —
    # 프록시의 client_max_body_size(nginx) 병행이 전제(main.ContentLengthLimitMiddleware).
    max_body_bytes: int = 16 * 1024

    # --- 커스텀 트랙 공유 허브(/api/community/*) ---
    # 본문 상한(바이트, 기본 1MiB). 이 경로는 선언된 Content-Length 뿐 아니라 실제 수신
    # 바이트도 세어, 길이 누락·거짓·chunked 전송이어도 상한을 넘는 즉시 413 을 돌려준다.
    # 다른 경로(/api/runs 등)는 위 max_body_bytes 를 그대로 쓴다.
    community_max_body_bytes: int = 1024 * 1024
    # 게시(POST) IP당 분당/일일 허용 횟수. 0 이하면 해당 제한을 끈다.
    community_post_per_minute: int = 3
    community_post_per_day: int = 30
    # 조회(GET 목록·상세) IP당 분당 허용 횟수.
    community_read_per_minute: int = 120
    # 삭제(DELETE) IP당 분당 허용 횟수(삭제 토큰 추측 방어).
    community_delete_per_minute: int = 10

    # 공식 트랙 스냅샷 디렉토리(game/tracks/official 에서 복사해 둔 것).
    tracks_dir: Path = _APP_DIR / "tracks"

    # 물리 하한 계산용 최고 속도(px/s). 기획서 §7.2 Overlock 단계 = 300.
    max_speed_px_s: float = 300.0
    # 물리 하한 안전계수(§18). 코너컷으로 실주행거리 < 중심선 길이가 되면 (중심선/최고속도)
    # 기준 하한이 정당한 기록을 오거부한다. 계수(<1)를 곱해 하한을 낮춰 이를 보정한다.
    # OVERLOCK_MIN_TIME_SAFETY_FACTOR 로 오버라이드(env_prefix 기존 패턴).
    min_time_safety_factor: float = 0.75

    @field_validator("tracks_dir", mode="before")
    @classmethod
    def _expand_tracks_dir(cls, value: object) -> object:
        if isinstance(value, str):
            return Path(value)
        return value

    def cors_origin_list(self) -> list[str]:
        """CORS 정확-일치 허용 오리진 목록. ``*`` 단일이면 전체 허용."""
        raw = [o.strip() for o in self.cors_origins.split(",") if o.strip()]
        return raw or ["*"]

    def cors_origin_regex_or_none(self) -> str | None:
        """CORS 허용 오리진 정규식(빈 값이면 None — 정규식 매칭 비활성)."""
        regex = self.cors_origin_regex.strip()
        return regex or None

    def cors_method_list(self) -> list[str]:
        """CORS 허용 메서드 목록(대문자 정규화). 빈 값이면 GET/POST/DELETE."""
        methods = [m.strip().upper() for m in self.cors_allow_methods.split(",") if m.strip()]
        return methods or ["GET", "POST", "DELETE"]

    def cors_header_list(self) -> list[str]:
        """CORS 허용 요청 헤더 목록. 빈 값이면 Content-Type/Accept/Authorization."""
        headers = [h.strip() for h in self.cors_allow_headers.split(",") if h.strip()]
        return headers or ["Content-Type", "Accept", "Authorization"]


@lru_cache
def get_settings() -> Settings:
    """프로세스 전역 기본 설정(환경변수 반영). 테스트는 별도 Settings를 주입한다."""
    return Settings()
