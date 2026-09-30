"""FastAPI 앱 팩토리 (기획서 §12 스택, §13 API).

``create_app(settings)`` 로 엔진·세션·레이트리밋을 조립하고 기동 시 공식 트랙을
시드한다. 테스트는 임시 DB·낮은 레이트리밋을 담은 Settings 를 주입한다. uvicorn 은
모듈 전역 ``app`` 을 사용한다(``uvicorn app.main:app``).
"""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from . import __version__
from .community import COMMUNITY_PREFIX
from .community import router as community_router
from .config import Settings, get_settings
from .database import build_engine, build_sessionmaker, init_db
from .ratelimit import RateLimiter
from .routes import router
from .seed import seed_tracks


def _too_large_response(limit: int) -> JSONResponse:
    return JSONResponse(
        status_code=413,
        content={"detail": f"요청 본문이 너무 큽니다 (최대 {limit} bytes)"},
    )


# 실제 수신 바이트를 세며 버퍼링하는 메서드(본문을 읽는 엔드포인트만).
_BODY_METHODS = frozenset({"POST", "PUT", "PATCH"})


class ContentLengthLimitMiddleware:
    """요청 본문 크기 상한 ASGI 미들웨어(경로별 상한).

    기본 경로: Content-Length 가 max_body_bytes 를 넘으면 본문을 읽기 전에 413 으로
    차단한다. 이 경우 앱단 방어는 Content-Length 헤더를 신뢰하는 수준까지이므로 리버스
    프록시의 본문 크기 제한(nginx ``client_max_body_size`` 등)을 함께 두는 것을 전제로 한다.

    streamed_prefixes 경로(공유 허브 /api/community/): 선언 길이 검사에 더해, 본문을 읽는
    메서드(POST·PUT·PATCH)에서는 실제 수신 바이트를 세며 본문을 상한까지 버퍼링한다.
    Content-Length 누락·거짓·chunked 전송이어도 누적 바이트가 상한을 넘기 전에 413 을
    돌려주고(초과 청크는 복사하지 않고 더 receive 하지도 않는다), 통과한 본문만 하위 앱에
    재생한다. GET·DELETE·OPTIONS 등은 본문을 쓰지 않으므로 버퍼링하지 않고 그대로 넘긴다.
    """

    def __init__(
        self,
        app: ASGIApp,
        max_body_bytes: int,
        streamed_prefixes: tuple[tuple[str, int], ...] = (),
    ) -> None:
        self.app = app
        self.max_body_bytes = max_body_bytes
        self.streamed_prefixes = streamed_prefixes

    def _limit_for(self, path: str) -> tuple[int, bool]:
        for prefix, limit in self.streamed_prefixes:
            if path == prefix.rstrip("/") or path.startswith(prefix):
                return limit, True
        return self.max_body_bytes, False

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        limit, streamed = self._limit_for(scope.get("path", ""))
        if limit <= 0:
            await self.app(scope, receive, send)
            return
        for name, value in scope["headers"]:
            if name != b"content-length":
                continue
            try:
                declared = int(value)
            except ValueError:
                break  # 파싱 불가한 Content-Length 는 하위 앱(또는 스트리밍 계수)이 처리한다.
            if declared > limit:
                await _too_large_response(limit)(scope, receive, send)
                return
            break
        if not streamed or scope.get("method", "GET").upper() not in _BODY_METHODS:
            await self.app(scope, receive, send)
            return

        # 실제 수신 바이트 계수 + 버퍼링(상한 1MiB 수준이라 메모리 부담이 작다).
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return  # 클라이언트가 끊겼으면 응답할 대상이 없다.
            chunk = message.get("body", b"")
            if len(body) + len(chunk) > limit:
                await _too_large_response(limit)(scope, receive, send)
                return
            body.extend(chunk)
            if not message.get("more_body", False):
                break

        replayed = False

        async def replay_receive() -> Message:
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        await self.app(scope, replay_receive, send)


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
    # 공유 허브 전용 버킷(기록 제출 버킷과 독립). 게시는 분당·일일 두 윈도를 모두 통과해야 한다.
    app.state.community_limiters = {
        "post_minute": RateLimiter(settings.community_post_per_minute),
        "post_day": RateLimiter(settings.community_post_per_day, window_seconds=86400.0),
        "read": RateLimiter(settings.community_read_per_minute),
        "delete": RateLimiter(settings.community_delete_per_minute),
    }

    # 요청 본문 크기 상한(DoS 방어): Content-Length 초과 시 413 조기 차단.
    # CORS 미들웨어보다 "먼저" add 한다 → CORS 가 바깥쪽이 되어 413 응답에도 CORS
    # 헤더가 붙는다(Starlette 는 나중에 add_middleware 한 것이 바깥쪽). 한계:
    # 기본 경로는 chunked/거짓 Content-Length 를 못 막으므로 nginx client_max_body_size 병행 전제.
    # 공유 허브 경로만 별도 상한(1MiB)으로 실제 수신 바이트까지 센다.
    app.add_middleware(
        ContentLengthLimitMiddleware,
        max_body_bytes=settings.max_body_bytes,
        streamed_prefixes=((COMMUNITY_PREFIX + "/", settings.community_max_body_bytes),),
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
    app.include_router(community_router)
    return app


# uvicorn 진입점: `uvicorn app.main:app`
app = create_app()
