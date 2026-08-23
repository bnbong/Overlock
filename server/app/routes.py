"""API 라우트 (기획서 §13.3 엔드포인트 + §14 정렬 + §18 필터).

정상 제출/조회, 리더보드 정렬(플레이어당 최고 1건), 비정상 기록 필터(체크섬·물리
하한·레이트리밋)를 담당한다. DB 없는 범위 검증은 schemas.py 가 이미 처리한다.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session, aliased

from . import __version__
from .config import Settings
from .database import get_session
from .models import Run, Track
from .ratelimit import RateLimiter
from .schemas import (
    HealthResponse,
    LeaderboardEntry,
    LeaderboardResponse,
    RunCreate,
    RunDetail,
    RunSubmitResponse,
    TrackInfo,
)

router = APIRouter(prefix="/api")

# 422: 비정상 기록 필터 거부 코드. Starlette 버전별 상수명 변경(ENTITY→CONTENT)에
# 영향받지 않도록 정수 상수를 직접 쓴다.
HTTP_422_UNPROCESSABLE = 422

def _leaderboard_order(entity):
    """리더보드 정렬 키(기획서 §14.1). id 는 완전 결정성을 위한 최종 타이브레이커.

    윈도 함수(플레이어당 최고 1건 선별)와 전역 정렬·순위 산출에 완전히 동일한 키를
    쓰기 위해, 원본 ``Run`` 또는 서브쿼리 alias 를 받아 같은 순서로 생성한다.
    """
    return (
        entity.final_time_ms.asc(),
        entity.accuracy.desc(),
        entity.cuts.asc(),
        entity.off_seam_ms.asc(),
        entity.created_at.asc(),
        entity.id.asc(),
    )


# 원본 Run 기준 정렬 키(윈도 함수 ORDER BY 및 참조용).
_LEADERBOARD_ORDER = _leaderboard_order(Run)

LEADERBOARD_LIMIT_MAX = 500


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def get_rate_limiter(request: Request) -> RateLimiter:
    return request.app.state.rate_limiter


def _client_key(request: Request, settings: Settings) -> str:
    """레이트리밋 키(클라이언트 IP).

    신뢰 프록시 뒤 배포를 전제로 X-Forwarded-For 에서 "끝에서 trusted_proxy_hops
    번째" 값을 실제 클라이언트 IP 로 쓴다. 각 신뢰 프록시가 다운스트림 IP 를 XFF
    오른쪽에 덧붙이므로, 홉 수만큼 뒤에서 세면 클라이언트가 조작할 수 있는 선두
    (왼쪽) 값에 오염되지 않는다. 값이 홉 수보다 적으면(프록시 우회 직접 접속 등)
    선두값을 신뢰하지 않고 실제 peer(request.client) 로 폴백한다.
    """
    if settings.trust_forwarded_for:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            parts = [p.strip() for p in forwarded.split(",") if p.strip()]
            hops = settings.trusted_proxy_hops
            if hops >= 1 and len(parts) >= hops:
                return parts[-hops]
    return request.client.host if request.client else "unknown"


def _best_rows_subquery(track_id: str, difficulty: str | None):
    """플레이어별 순위(row_number)를 매긴 서브쿼리. rn==1 이 그 플레이어의 최고 기록.

    윈도 함수 ``row_number() OVER (PARTITION BY player_name ORDER BY <정렬 키>)`` 로
    플레이어당 베스트 1건을 SQL 단계에서 선별한다(전체 스캔 + Python dedup 제거).
    """
    best_rn = (
        func.row_number()
        .over(partition_by=Run.player_name, order_by=_LEADERBOARD_ORDER)
        .label("player_best_rn")
    )
    stmt = select(Run, best_rn).where(Run.track_id == track_id)
    if difficulty is not None:
        stmt = stmt.where(Run.difficulty == difficulty)
    return stmt.subquery()


def _leaderboard_page(
    session: Session,
    track_id: str,
    difficulty: str | None,
    limit: int,
    offset: int,
) -> list[Run]:
    """플레이어당 최고 1건만 남겨 순위순으로 정렬한 뒤 LIMIT/OFFSET 을 SQL 에서 적용한 페이지."""
    subq = _best_rows_subquery(track_id, difficulty)
    best = aliased(Run, subq)
    stmt = (
        select(best)
        .where(subq.c.player_best_rn == 1)
        .order_by(*_leaderboard_order(best))
        .limit(limit)
        .offset(offset)
    )
    return list(session.scalars(stmt))


def _leaderboard_total(
    session: Session, track_id: str, difficulty: str | None
) -> int:
    """리더보드 총 행 수(= 트랙·난이도 필터에서 서로 다른 player_name 수)."""
    stmt = select(func.count(func.distinct(Run.player_name))).where(
        Run.track_id == track_id
    )
    if difficulty is not None:
        stmt = stmt.where(Run.difficulty == difficulty)
    return session.scalar(stmt) or 0


def _player_rank(
    session: Session, track_id: str, difficulty: str | None, player_name: str
) -> int:
    """전체 베스트 목록(플레이어당 1건, 순위순)에서 player_name 의 1-based 순위. 없으면 0."""
    subq = _best_rows_subquery(track_id, difficulty)
    best = aliased(Run, subq)
    global_rank = (
        func.row_number()
        .over(order_by=_leaderboard_order(best))
        .label("global_rank")
    )
    ranked = (
        select(best.player_name.label("player_name"), global_rank)
        .where(subq.c.player_best_rn == 1)
        .subquery()
    )
    stmt = select(ranked.c.global_rank).where(ranked.c.player_name == player_name)
    return session.scalar(stmt) or 0


@router.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    return HealthResponse(status="ok", version=__version__)


@router.get("/tracks", response_model=list[TrackInfo])
def list_tracks(session: Session = Depends(get_session)) -> list[TrackInfo]:
    tracks = session.scalars(select(Track).order_by(Track.created_at.asc(), Track.id.asc()))
    return [
        TrackInfo(
            id=track.id,
            name=track.name,
            difficulty=track.difficulty,
            checksum=track.checksum,
        )
        for track in tracks
    ]


@router.get("/leaderboard", response_model=LeaderboardResponse)
def get_leaderboard(
    track_id: str = Query(..., min_length=1),
    difficulty: str | None = Query(default=None, max_length=32),
    limit: int = Query(default=100, ge=1, le=LEADERBOARD_LIMIT_MAX),
    offset: int = Query(default=0, ge=0),
    session: Session = Depends(get_session),
) -> LeaderboardResponse:
    if session.get(Track, track_id) is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"등록되지 않은 track_id: {track_id}",
        )

    page = _leaderboard_page(session, track_id, difficulty, limit, offset)
    total = _leaderboard_total(session, track_id, difficulty)
    entries = [
        LeaderboardEntry(
            rank=offset + i + 1,
            run_id=run.id,
            player_name=run.player_name,
            track_id=run.track_id,
            difficulty=run.difficulty,
            time_ms=run.time_ms,
            penalty_ms=run.penalty_ms,
            final_time_ms=run.final_time_ms,
            accuracy=run.accuracy,
            cuts=run.cuts,
            off_seam_ms=run.off_seam_ms,
            game_version=run.game_version,
            verification_status=run.verification_status,
            created_at=run.created_at,
        )
        for i, run in enumerate(page)
    ]
    return LeaderboardResponse(
        track_id=track_id,
        difficulty=difficulty,
        limit=limit,
        offset=offset,
        count=total,
        entries=entries,
    )


@router.post(
    "/runs",
    response_model=RunSubmitResponse,
    status_code=status.HTTP_201_CREATED,
)
def submit_run(
    payload: RunCreate,
    request: Request,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings_dep),
    limiter: RateLimiter = Depends(get_rate_limiter),
) -> RunSubmitResponse:
    # 1) 레이트리밋(§18): IP당 분당 N회.
    if not limiter.allow(_client_key(request, settings)):
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="요청이 너무 잦습니다. 잠시 후 다시 시도하세요.",
        )

    # 2) 트랙 등록 여부(§18): 미등록 → 422.
    track = session.get(Track, payload.track_id)
    if track is None:
        raise HTTPException(
            status_code=HTTP_422_UNPROCESSABLE,
            detail=f"등록되지 않은 track_id: {payload.track_id}",
        )

    # 3) 체크섬 대조(§13.2/§18): 불일치 → 422.
    if payload.track_checksum != track.checksum:
        raise HTTPException(
            status_code=HTTP_422_UNPROCESSABLE,
            detail="track_checksum이 등록된 트랙 체크섬과 일치하지 않습니다",
        )

    # 4) 물리 하한(§18): 최고속도로도 불가능한 기록 → 422.
    if payload.final_time_ms < track.min_final_time_ms:
        raise HTTPException(
            status_code=HTTP_422_UNPROCESSABLE,
            detail=(
                "final_time_ms가 물리적 최소 완주 시간보다 빠릅니다 "
                f"(min={track.min_final_time_ms}ms)"
            ),
        )

    # 5) 저장(verification_status 기본 'unverified', §14.2).
    run = Run(
        player_name=payload.player_name,
        track_id=payload.track_id,
        difficulty=payload.difficulty,
        time_ms=payload.time_ms,
        penalty_ms=payload.penalty_ms,
        final_time_ms=payload.final_time_ms,
        accuracy=payload.accuracy,
        cuts=payload.cuts,
        off_seam_ms=payload.off_seam_ms,
        game_version=payload.game_version,
        track_checksum=payload.track_checksum,
        replay_hash=payload.replay_hash,
        verification_status="unverified",
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    session.add(run)
    session.commit()
    session.refresh(run)

    # 6) 순위 산출: 같은 트랙·난이도 리더보드에서 이 플레이어의 최고 기록 순위.
    rank = _player_rank(
        session, payload.track_id, payload.difficulty, payload.player_name
    )

    return RunSubmitResponse(
        run_id=run.id,
        verification_status=run.verification_status,
        rank=rank,
    )


@router.get("/runs/{run_id}", response_model=RunDetail)
def get_run(run_id: int, session: Session = Depends(get_session)) -> RunDetail:
    run = session.get(Run, run_id)
    if run is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"기록을 찾을 수 없습니다: run_id={run_id}",
        )
    return RunDetail.model_validate(run)
