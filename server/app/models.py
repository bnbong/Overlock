"""SQLAlchemy ORM 모델 (기획서 §13.4 스키마 그대로 + 최소 확장).

기본 컬럼은 기획서 DDL과 1:1 대응하며, ``tracks`` 에 물리 하한 필터(§18)에 쓰는
``length_px``·``min_final_time_ms`` 두 컬럼만 확장으로 추가했다. SQLite/PostgreSQL
양쪽에서 동일 코드로 동작하도록 SQLAlchemy 2.0 타입만 사용한다.
"""

from __future__ import annotations

from sqlalchemy import ForeignKey, Index, Integer, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.types import Float


class Base(DeclarativeBase):
    pass


class Track(Base):
    """공식 트랙 등록 정보. 시드 시 스냅샷 JSON에서 채워진다."""

    __tablename__ = "tracks"

    id: Mapped[str] = mapped_column(Text, primary_key=True)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    difficulty: Mapped[str] = mapped_column(Text, nullable=False)
    # 트랙 JSON 파일 바이트의 SHA-256("sha256:<hex>"). 클라이언트 제출값과 대조(§13.2).
    checksum: Mapped[str] = mapped_column(Text, nullable=False)
    # --- 확장 컬럼(§18 물리 하한 필터) ---
    length_px: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # 물리적으로 가능한 최소 완주 시간(ms) = (length_px / max_speed) * 1000. 시드 시 계산·저장.
    min_final_time_ms: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[str] = mapped_column(Text, nullable=False)


class Run(Base):
    """제출된 기록 한 건. verification_status 기본 'unverified'(§14.2)."""

    __tablename__ = "runs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    player_name: Mapped[str] = mapped_column(Text, nullable=False)
    track_id: Mapped[str] = mapped_column(Text, ForeignKey("tracks.id"), nullable=False)
    difficulty: Mapped[str] = mapped_column(Text, nullable=False)
    time_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    penalty_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    final_time_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    accuracy: Mapped[float] = mapped_column(Float, nullable=False)
    cuts: Mapped[int] = mapped_column(Integer, nullable=False)
    off_seam_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    game_version: Mapped[str] = mapped_column(Text, nullable=False)
    track_checksum: Mapped[str] = mapped_column(Text, nullable=False)
    replay_hash: Mapped[str | None] = mapped_column(Text, nullable=True)
    verification_status: Mapped[str] = mapped_column(
        Text, nullable=False, default="unverified"
    )
    created_at: Mapped[str] = mapped_column(Text, nullable=False)

    # 리더보드 정렬·필터용 인덱스(기획서 §13.4).
    __table_args__ = (
        Index(
            "idx_runs_leaderboard",
            "track_id",
            "difficulty",
            "final_time_ms",
            "accuracy",
            "cuts",
        ),
    )
