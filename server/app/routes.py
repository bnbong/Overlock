"""API 라우트 (기획서 §13.3 엔드포인트 + §14 정렬 + §18 필터).

정상 제출/조회, 리더보드 정렬(플레이어당 최고 1건), 비정상 기록 필터(체크섬·물리
하한·레이트리밋)를 담당한다. DB 없는 범위 검증은 schemas.py 가 이미 처리한다.
"""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

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

# 리더보드 정렬 키(기획서 §14.1). id 는 완전 결정성을 위한 최종 타이브레이커.
_LEADERBOARD_ORDER = (
    Run.final_time_ms.asc(),
    Run.accuracy.desc(),
    Run.cuts.asc(),
    Run.off_seam_ms.asc(),
    Run.created_at.asc(),
    Run.id.asc(),
)

LEADERBOARD_LIMIT_MAX = 500


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def get_rate_limiter(request: Request) -> RateLimiter:
    return request.app.state.rate_limiter


def _client_key(request: Request, settings: Settings) -> str:
    """레이트리밋 키(클라이언트 IP). 프록시 뒤에서는 X-Forwarded-For 선두 IP 사용."""
    if settings.trust_forwarded_for:
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _leaderboard_rows(
    session: Session, track_id: str, difficulty: str | None
) -> list[Run]:
    """정렬된 뒤 플레이어당 최고 1건만 남긴 리더보드 행(전체). 이미 순위 순."""
    stmt = select(Run).where(Run.track_id == track_id)
    if difficulty is not None:
        stmt = stmt.where(Run.difficulty == difficulty)
    stmt = stmt.order_by(*_LEADERBOARD_ORDER)

    seen: set[str] = set()
    deduped: list[Run] = []
    for run in session.scalars(stmt):
        if run.player_name in seen:
            continue
        seen.add(run.player_name)
        deduped.append(run)
    return deduped


def _player_rank(rows: list[Run], player_name: str) -> int:
    """정렬된 리더보드에서 player_name 의 순위(1-based). 없으면 0."""
    for index, run in enumerate(rows):
        if run.player_name == player_name:
            return index + 1
    return 0


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
    difficulty: str | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=LEADERBOARD_LIMIT_MAX),
    offset: int = Query(default=0, ge=0),
    session: Session = Depends(get_session),
) -> LeaderboardResponse:
    if session.get(Track, track_id) is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"등록되지 않은 track_id: {track_id}",
        )

    rows = _leaderboard_rows(session, track_id, difficulty)
    page = rows[offset : offset + limit]
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
        count=len(rows),
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
    rows = _leaderboard_rows(session, payload.track_id, payload.difficulty)
    rank = _player_rank(rows, payload.player_name)

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
