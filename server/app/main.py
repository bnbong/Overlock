"""FastAPI 앱 팩토리 (기획서 §12 스택, §13 API).

``create_app(settings)`` 로 엔진·세션·레이트리밋을 조립하고 기동 시 공식 트랙을
시드한다. 테스트는 임시 DB·낮은 레이트리밋을 담은 Settings 를 주입한다. uvicorn 은
모듈 전역 ``app`` 을 사용한다(``uvicorn app.main:app``).
"""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import __version__
from .config import Settings, get_settings
from .database import build_engine, build_sessionmaker, init_db
from .ratelimit import RateLimiter
from .routes import router
from .seed import seed_tracks


def create_app(settings: Settings | None = None) -> FastAPI:
    """설정을 받아 앱을 구성한다. settings 미지정 시 환경변수 기반 기본 설정."""
    settings = settings or get_settings()

    app = FastAPI(
        title="Overlock Leaderboard API",
        version=__version__,
        description="재봉 레이싱 게임 Overlock 의 리더보드 서버 (기획서 §13).",
    )

    # 엔진·스키마·세션 준비.
    engine = build_engine(settings.db_url)
    init_db(engine)
    sessionmaker = build_sessionmaker(engine)

    # 공식 트랙 시드(스냅샷 → tracks 테이블). 스냅샷 없으면 조용히 건너뛴다.
    if settings.tracks_dir.is_dir():
        with sessionmaker() as session:
            seed_tracks(session, settings.tracks_dir, settings.max_speed_px_s)

    # 앱 상태에 의존성 원본을 보관(라우트에서 request.app.state 로 접근).
    app.state.settings = settings
    app.state.engine = engine
    app.state.sessionmaker = sessionmaker
    app.state.rate_limiter = RateLimiter(settings.rate_limit_per_minute)

    # CORS: 전체 허용 기본(오픈소스 웹 클라이언트), config 로 제한 가능.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list(),
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(router)
    return app


# uvicorn 진입점: `uvicorn app.main:app`
app = create_app()
