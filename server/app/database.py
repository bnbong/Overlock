"""SQLAlchemy 엔진·세션 관리 (기획서 §12: SQLite 기본, PostgreSQL 전환 여지).

``build_engine`` 은 URL만 바꾸면 SQLite/PostgreSQL 어느 쪽이든 동작한다.
FastAPI 라우트는 ``get_session`` 의존성으로 요청마다 세션을 받는다.
"""

from __future__ import annotations

from collections.abc import Iterator

from fastapi import Request
from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session, sessionmaker

from .models import Base


def build_engine(db_url: str) -> Engine:
    """DB URL로 엔진을 만든다. SQLite는 스레드 공유·경량 옵션을 적용한다."""
    connect_args: dict[str, object] = {}
    if db_url.startswith("sqlite"):
        # FastAPI는 여러 스레드에서 커넥션을 쓸 수 있으므로 SQLite 체크를 완화한다.
        connect_args["check_same_thread"] = False
    engine = create_engine(db_url, connect_args=connect_args, future=True)
    return engine


def build_sessionmaker(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine, autoflush=False, expire_on_commit=False, future=True)


def init_db(engine: Engine) -> None:
    """테이블·인덱스를 생성한다(이미 있으면 무시)."""
    Base.metadata.create_all(engine)


def get_session(request: Request) -> Iterator[Session]:
    """요청 스코프 세션 의존성. app.state.sessionmaker 에서 세션을 발급한다."""
    maker: sessionmaker[Session] = request.app.state.sessionmaker
    session = maker()
    try:
        yield session
    finally:
        session.close()
