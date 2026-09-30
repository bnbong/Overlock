"""커스텀 트랙 공유 허브 API (계획서 §3).

계정 없는 불변 게시 + 삭제 토큰 모델이다. 공식 트랙 기록 체계(/api/tracks·/api/runs·
/api/leaderboard)와 테이블·레이트리밋 버킷을 공유하지 않는다.

  GET    /api/community/tracks            공개 목록(최신순, 제목 부분 일치 검색, total 포함)
  GET    /api/community/tracks/{id}       메타데이터 + 검증된 track JSON + content_hash
  POST   /api/community/tracks            게시(201, id 와 삭제 토큰을 이 응답에서만 반환)
  DELETE /api/community/tracks/{id}       Bearer 삭제 토큰 검증 후 소프트 삭제(204)

오류 본문은 FastAPI 관례를 따른다: 422 는 detail 이 [{loc,msg,type}] 목록, 그 외
(401/403/404/413/429)는 detail 이 문자열이다. 삭제 토큰·토큰 해시·IP 는 어떤 응답과
로그에도 싣지 않는다.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Path, Query, Request, Response, status
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool
from pydantic import BaseModel
from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from .community_validation import (
    TITLE_MAX,
    TrackRejected,
    normalize_search_query,
    validate_upload,
)
from .config import Settings
from .database import get_session
from .models import CommunityTrack
from .ratelimit import RateLimiter
from .routes import _client_key, get_settings_dep

COMMUNITY_PREFIX = "/api/community"
router = APIRouter(prefix=COMMUNITY_PREFIX, tags=["community"])

LIST_LIMIT_DEFAULT = 20
LIST_LIMIT_MAX = 50
# 삭제 토큰 원문 상한(정상 토큰은 token_urlsafe(32) → 43자). 이보다 길면 형식 오류(401).
_TOKEN_MAX_LEN = 256
# UUID 문자열 경로 파라미터 상한(36자). 과대 입력은 조회 전에 404 로 끝낸다.
_ID_MAX_LEN = 64

_TOO_MANY = "요청이 너무 잦습니다. 잠시 후 다시 시도하세요."
_NOT_FOUND = "게시물을 찾을 수 없습니다"


# ---------------------------------------------------------------------------
# 응답 스키마
# ---------------------------------------------------------------------------
class CommunityTrackSummary(BaseModel):
    """목록 항목(전체 JSON·토큰·해시 미포함)."""

    id: str
    title: str
    author_name: str
    difficulty: str
    fabric: str
    length: int
    created_at: str


class CommunityTrackList(BaseModel):
    total: int
    limit: int
    offset: int
    q: str
    items: list[CommunityTrackSummary]


class CommunityTrackDetail(BaseModel):
    id: str
    title: str
    author_name: str
    description: str
    difficulty: str
    fabric: str
    length: int
    created_at: str
    content_hash: str
    track: dict


class CommunityTrackCreated(CommunityTrackDetail):
    """게시 응답. delete_token 은 이 응답에서만 한 번 반환된다(서버는 해시만 보관)."""

    delete_token: str


# ---------------------------------------------------------------------------
# 의존성·헬퍼
# ---------------------------------------------------------------------------
def get_community_limiters(request: Request) -> dict[str, RateLimiter]:
    return request.app.state.community_limiters


def _rate_limit(limiter: RateLimiter, key: str) -> None:
    if not limiter.allow(key):
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail=_TOO_MANY)


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _escape_like(text: str) -> str:
    """LIKE 와일드카드(% _)와 이스케이프 문자(\\)를 리터럴로 취급하도록 이스케이프한다."""
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _detail(row: CommunityTrack) -> CommunityTrackDetail:
    return CommunityTrackDetail(
        id=row.id,
        title=row.title,
        author_name=row.author_name,
        description=row.description,
        difficulty=row.difficulty,
        fabric=row.fabric,
        length=row.length_px,
        created_at=row.created_at,
        content_hash=row.content_hash,
        track=json.loads(row.track_json),
    )


def _get_visible(session: Session, track_id: str) -> CommunityTrack:
    if len(track_id) > _ID_MAX_LEN:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=_NOT_FOUND)
    row = session.get(CommunityTrack, track_id)
    if row is None or row.deleted_at is not None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=_NOT_FOUND)
    return row


def _bearer_token(request: Request) -> str | None:
    """Authorization: Bearer <token> 에서 토큰을 꺼낸다. 없거나 형식이 틀리면 None."""
    header = request.headers.get("authorization")
    if not header:
        return None
    scheme, _, token = header.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token or len(token) > _TOKEN_MAX_LEN:
        return None
    return token


# ---------------------------------------------------------------------------
# 엔드포인트
# ---------------------------------------------------------------------------
@router.get("/tracks", response_model=CommunityTrackList)
def list_community_tracks(
    request: Request,
    q: str = Query(default="", max_length=TITLE_MAX * 4),
    limit: int = Query(default=LIST_LIMIT_DEFAULT, ge=1, le=LIST_LIMIT_MAX),
    offset: int = Query(default=0, ge=0, le=1_000_000),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings_dep),
    limiters: dict[str, RateLimiter] = Depends(get_community_limiters),
) -> CommunityTrackList:
    _rate_limit(limiters["read"], _client_key(request, settings))

    query = normalize_search_query(q)
    if len(query) > TITLE_MAX:
        raise HTTPException(
            status_code=422,
            detail=[
                {
                    "loc": ["query", "q"],
                    "msg": f"검색어는 최대 {TITLE_MAX}자입니다",
                    "type": "string_too_long",
                }
            ],
        )

    conditions = [CommunityTrack.deleted_at.is_(None)]
    if query:
        # 바인딩 파라미터 + ESCAPE '\' 로 와일드카드를 리터럴 처리. ilike 는 SQLite/PostgreSQL
        # 모두에서 ASCII 대소문자를 구분하지 않는다(한글 등은 그대로 부분 일치).
        conditions.append(
            CommunityTrack.title.ilike(f"%{_escape_like(query)}%", escape="\\")
        )

    total = session.scalar(select(func.count()).select_from(CommunityTrack).where(*conditions)) or 0
    rows = session.scalars(
        select(CommunityTrack)
        .where(*conditions)
        .order_by(CommunityTrack.created_at.desc(), CommunityTrack.id.desc())
        .limit(limit)
        .offset(offset)
    )
    items = [
        CommunityTrackSummary(
            id=row.id,
            title=row.title,
            author_name=row.author_name,
            difficulty=row.difficulty,
            fabric=row.fabric,
            length=row.length_px,
            created_at=row.created_at,
        )
        for row in rows
    ]
    return CommunityTrackList(total=total, limit=limit, offset=offset, q=query, items=items)


@router.get("/tracks/{track_id}", response_model=CommunityTrackDetail)
def get_community_track(
    request: Request,
    track_id: str = Path(...),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings_dep),
    limiters: dict[str, RateLimiter] = Depends(get_community_limiters),
) -> CommunityTrackDetail:
    _rate_limit(limiters["read"], _client_key(request, settings))
    return _detail(_get_visible(session, track_id))


@router.post(
    "/tracks",
    response_model=CommunityTrackCreated,
    status_code=status.HTTP_201_CREATED,
    openapi_extra={
        "requestBody": {
            "required": True,
            "content": {
                "application/json": {
                    "schema": {
                        "type": "object",
                        "required": ["title", "author_name", "track"],
                        "properties": {
                            "title": {"type": "string", "maxLength": 80},
                            "author_name": {"type": "string", "maxLength": 32},
                            "description": {"type": "string", "maxLength": 1000},
                            "track": {"type": "object"},
                        },
                    }
                }
            },
        }
    },
)
async def create_community_track(
    request: Request,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings_dep),
    limiters: dict[str, RateLimiter] = Depends(get_community_limiters),
) -> JSONResponse:
    key = _client_key(request, settings)
    # 분당 → 일일 순서. 분당 한도에 걸린 요청은 일일 카운트를 소모하지 않는다.
    _rate_limit(limiters["post_minute"], key)
    _rate_limit(limiters["post_day"], key)

    # 본문은 ContentLengthLimitMiddleware 가 실제 바이트 기준 상한까지 버퍼링해 두었다.
    body = await request.body()
    # 검증(기하 계산)과 동기 DB 쓰기는 이벤트 루프를 막지 않도록 스레드풀에서 수행한다.
    return await run_in_threadpool(_create_sync, session, body)


def _now_iso() -> str:
    # 마이크로초 자릿수를 고정해 문자열 정렬이 시간 순서와 항상 일치하게 한다.
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def _create_sync(session: Session, body: bytes) -> JSONResponse:
    try:
        upload = validate_upload(body)
    except TrackRejected as exc:
        return JSONResponse(status_code=422, content={"detail": exc.errors})

    token = secrets.token_urlsafe(32)
    row = CommunityTrack(
        id=str(uuid.uuid4()),
        title=upload.title,
        author_name=upload.author_name,
        description=upload.description,
        difficulty=upload.difficulty,
        fabric=upload.fabric,
        length_px=upload.length,
        track_json=json.dumps(upload.track, ensure_ascii=False, separators=(",", ":")),
        content_hash=upload.content_hash,
        created_at=_now_iso(),
        delete_token_hash=_hash_token(token),
        deleted_at=None,
    )
    session.add(row)
    session.commit()

    created = CommunityTrackCreated(**_detail(row).model_dump(), delete_token=token)
    return JSONResponse(
        status_code=status.HTTP_201_CREATED,
        content=created.model_dump(),
        headers={"Cache-Control": "no-store"},
    )


@router.delete("/tracks/{track_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_community_track(
    request: Request,
    track_id: str = Path(...),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings_dep),
    limiters: dict[str, RateLimiter] = Depends(get_community_limiters),
) -> Response:
    """삭제 규칙: 토큰 없음/형식 오류 401 → 게시물 없음·이미 삭제 404 → 토큰 불일치 403 → 204."""
    _rate_limit(limiters["delete"], _client_key(request, settings))

    token = _bearer_token(request)
    if token is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="삭제 토큰이 필요합니다 (Authorization: Bearer <delete_token>)",
            headers={"WWW-Authenticate": "Bearer"},
        )

    row = _get_visible(session, track_id)
    if not hmac.compare_digest(_hash_token(token), row.delete_token_hash):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="삭제 토큰이 올바르지 않습니다")

    # 원자적 소프트 삭제: 조회 이후 다른 요청이 먼저 지웠다면 갱신 행이 0 이므로 404.
    result = session.execute(
        update(CommunityTrack)
        .where(CommunityTrack.id == row.id, CommunityTrack.deleted_at.is_(None))
        .values(deleted_at=_now_iso())
    )
    session.commit()
    if result.rowcount == 0:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=_NOT_FOUND)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
