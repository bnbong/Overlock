"""FastAPI 앱 팩토리 (기획서 §12 스택, §13 API).

``create_app(settings)`` 로 엔진·세션·레이트리밋을 조립하고 기동 시 공식 트랙을
시드한다. 테스트는 임시 DB·낮은 레이트리밋을 담은 Settings 를 주입한다. uvicorn 은
모듈 전역 ``app`` 을 사용한다(``uvicorn app.main:app``).
"""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from . import __version__
from .config import Settings, get_settings
from .database import build_engine, build_sessionmaker, init_db
from .ratelimit import RateLimiter
from .routes import router
from .seed import seed_tracks


class ContentLengthLimitMiddleware:
    """Content-Length 가 상한을 넘으면 본문을 읽기 전에 413 으로 차단하는 ASGI 미들웨어.

    앱단 방어는 Content-Length 헤더를 신뢰하는 수준까지다. chunked 전송이나 거짓
    Content-Length 는 여기서 막지 못하므로, 리버스 프록시의 본문 크기 제한
    (nginx ``client_max_body_size`` 등)을 함께 두는 것을 전제로 한다.
    """

    def __init__(self, app: ASGIApp, max_body_bytes: int) -> None:
        self.app = app
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and self.max_body_bytes > 0:
            for name, value in scope["headers"]:
                if name != b"content-length":
                    continue
                try:
                    declared = int(value)
                except ValueError:
                    break  # 파싱 불가한 Content-Length 는 하위 앱이 처리하게 둔다.
                if declared > self.max_body_bytes:
                    response = JSONResponse(
                        status_code=413,
                        content={
                            "detail": (
                                "요청 본문이 너무 큽니다 "
                                f"(최대 {self.max_body_bytes} bytes)"
                            )
                        },
                    )
                    await response(scope, receive, send)
                    return
                break
        await self.app(scope, receive, send)


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
            seed_tracks(
                session,
                settings.tracks_dir,
                settings.max_speed_px_s,
                settings.min_time_safety_factor,
            )

    # 앱 상태에 의존성 원본을 보관(라우트에서 request.app.state 로 접근).
    app.state.settings = settings
    app.state.engine = engine
    app.state.sessionmaker = sessionmaker
    app.state.rate_limiter = RateLimiter(settings.rate_limit_per_minute)

    # 요청 본문 크기 상한(DoS 방어): Content-Length 초과 시 413 조기 차단.
    # CORS 미들웨어보다 "먼저" add 한다 → CORS 가 바깥쪽이 되어 413 응답에도 CORS
    # 헤더가 붙는다(Starlette 는 나중에 add_middleware 한 것이 바깥쪽). 한계:
    # chunked/거짓 Content-Length 는 앱단에서 못 막으므로 nginx client_max_body_size 병행 전제.
    app.add_middleware(
        ContentLengthLimitMiddleware,
        max_body_bytes=settings.max_body_bytes,
    )

    # CORS: 정확-일치 오리진(config) + 정규식 오리진(itch.io *.itch.zone 임베드 등)을 허용한다.
    # 리더보드 API 는 인증 쿠키가 없어 credentials 는 비활성. 메서드·헤더는 config 로 제한 가능.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list(),
        allow_origin_regex=settings.cors_origin_regex_or_none(),
        allow_credentials=False,
        allow_methods=settings.cors_method_list(),
        allow_headers=settings.cors_header_list(),
    )

    app.include_router(router)
    return app


# uvicorn 진입점: `uvicorn app.main:app`
app = create_app()
