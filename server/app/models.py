"""SQLAlchemy ORM 모델 (기획서 §13.4 스키마 그대로 + 최소 확장).

기본 컬럼은 기획서 DDL과 1:1 대응하며, ``tracks`` 에 물리 하한 필터(§18)에 쓰는
``length_px``·``min_final_time_ms`` 두 컬럼만 확장으로 추가했다. SQLite/PostgreSQL
양쪽에서 동일 코드로 동작하도록 SQLAlchemy 2.0 타입만 사용한다.

``community_tracks`` 는 커스텀 트랙 공유 허브 전용 독립 테이블이다(공식 Track/Run 과
외래키·컬럼을 공유하지 않는다). 기존 DB 에는 create_all 이 이 테이블만 새로 만든다.
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
    # 재봉 등급 산정에 쓰는 perfect_rate(%). 등급 공식이 accuracy 와 함께 이 값을 가중하므로
    # 서버가 클라와 동일한 등급을 유도하려면 저장해야 한다(app/grade.py 상호 참조). 구버전
    # 클라이언트는 이 값을 보내지 않으므로 기본 0.0(등급이 다소 낮게 유도됨 — 하위 호환).
    perfect_rate: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
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


class CommunityTrack(Base):
    """공유 허브에 게시된 커스텀 트랙 한 건(불변 게시, 소프트 삭제).

    track_json 은 서버가 검증·정규화한 허용 필드만 담은 JSON 문자열이다. 삭제 토큰은
    원문을 저장하지 않고 SHA-256 hex 만 보관한다(delete_token_hash). deleted_at 이
    채워진 행은 게시자 삭제 또는 운영자 비공개 처리된 것으로 목록·상세에서 제외한다.
    """

    __tablename__ = "community_tracks"

    # 서버 발급 UUID4 문자열(공개 식별자).
    id: Mapped[str] = mapped_column(Text, primary_key=True)
    title: Mapped[str] = mapped_column(Text, nullable=False)
    author_name: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    # 목록 표시·필터용 컬럼(track_json 에서 복사).
    difficulty: Mapped[str] = mapped_column(Text, nullable=False)
    fabric: Mapped[str] = mapped_column(Text, nullable=False)
    length_px: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    track_json: Mapped[str] = mapped_column(Text, nullable=False)
    # 정규화 플레이 데이터(path·width·difficulty·fabric·items)의 "sha256:<hex>".
    content_hash: Mapped[str] = mapped_column(Text, nullable=False)
    # UTC ISO-8601 문자열(기존 테이블의 created_at 관례와 동일).
    created_at: Mapped[str] = mapped_column(Text, nullable=False)
    delete_token_hash: Mapped[str] = mapped_column(Text, nullable=False)
    deleted_at: Mapped[str | None] = mapped_column(Text, nullable=True, default=None)

    __table_args__ = (
        # 공개 목록: deleted_at IS NULL + created_at DESC, id DESC 정렬.
        Index("idx_community_tracks_list", "deleted_at", "created_at", "id"),
        Index("idx_community_tracks_content_hash", "content_hash"),
    )
