"""공유 허브 운영자 CLI (서버 셸에서만 실행, 공개 관리자 API 없음).

DB 는 서버와 같은 설정(OVERLOCK_DB_URL 등 환경변수/.env)으로 연다. 앱(app.main)을
임포트하지 않으므로 공식 트랙 시드나 레이트리밋 상태에 영향을 주지 않는다.

사용 예(server/ 디렉터리 또는 컨테이너 WORKDIR 에서):
    python -m app.community_admin list                 # 공개 게시물 최신순 50건
    python -m app.community_admin list --all -n 200    # 비공개(삭제) 포함
    python -m app.community_admin list -q 하트          # 제목 부분 일치
    python -m app.community_admin show <id>            # 한 건의 메타데이터(토큰 해시 제외)
    python -m app.community_admin hide <id>            # 비공개 처리(deleted_at 설정)
    python -m app.community_admin unhide <id>          # 비공개 해제(운영자 실수 복구용)

hide 는 게시자 삭제와 같은 소프트 삭제다. 행은 DB 에 남으므로 영구 제거가 필요하면
DB 백업 후 별도로 처리한다.
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone

from sqlalchemy import select

from .config import Settings
from .database import build_engine, build_sessionmaker, init_db
from .models import CommunityTrack


def _open_session(settings: Settings):
    engine = build_engine(settings.db_url)
    init_db(engine)  # 신규 테이블이 아직 없으면 만든다(기존 테이블은 건드리지 않음).
    return build_sessionmaker(engine)()


def _fmt_row(row: CommunityTrack) -> str:
    state = "hidden" if row.deleted_at else "public"
    return (
        f"{row.id}  {state:<6}  {row.created_at}  {row.difficulty:<8} {row.fabric:<8} "
        f"{row.length_px:>5}px  {row.author_name!r}  {row.title!r}"
    )


def cmd_list(session, args: argparse.Namespace) -> int:
    stmt = select(CommunityTrack)
    if not args.all:
        stmt = stmt.where(CommunityTrack.deleted_at.is_(None))
    if args.q:
        stmt = stmt.where(CommunityTrack.title.contains(args.q, autoescape=True))
    stmt = stmt.order_by(CommunityTrack.created_at.desc(), CommunityTrack.id.desc()).limit(
        args.n
    )
    rows = list(session.scalars(stmt))
    for row in rows:
        print(_fmt_row(row))
    print(f"-- {len(rows)} row(s)")
    return 0


def cmd_show(session, args: argparse.Namespace) -> int:
    row = session.get(CommunityTrack, args.id)
    if row is None:
        print(f"not found: {args.id}", file=sys.stderr)
        return 1
    print(_fmt_row(row))
    print(f"content_hash: {row.content_hash}")
    print(f"deleted_at:   {row.deleted_at}")
    print(f"description:  {row.description!r}")
    return 0


def _set_hidden(session, track_id: str, hidden: bool) -> int:
    row = session.get(CommunityTrack, track_id)
    if row is None:
        print(f"not found: {track_id}", file=sys.stderr)
        return 1
    if hidden and row.deleted_at is not None:
        print(f"already hidden: {track_id} (deleted_at={row.deleted_at})")
        return 0
    if not hidden and row.deleted_at is None:
        print(f"already public: {track_id}")
        return 0
    row.deleted_at = (
        datetime.now(timezone.utc).isoformat(timespec="microseconds") if hidden else None
    )
    session.commit()
    print(f"{'hidden' if hidden else 'unhidden'}: {track_id}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m app.community_admin",
        description="Overlock 공유 허브 운영자 도구(비공개 처리).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="게시물 목록(최신순)")
    p_list.add_argument("--all", action="store_true", help="비공개(삭제) 게시물 포함")
    p_list.add_argument("-n", type=int, default=50, help="최대 행 수(기본 50)")
    p_list.add_argument("-q", default="", help="제목 부분 일치 필터")

    p_show = sub.add_parser("show", help="게시물 한 건 보기")
    p_show.add_argument("id")

    p_hide = sub.add_parser("hide", help="게시물 비공개 처리")
    p_hide.add_argument("id")

    p_unhide = sub.add_parser("unhide", help="비공개 해제")
    p_unhide.add_argument("id")
    return parser


def main(argv: list[str] | None = None, settings: Settings | None = None) -> int:
    args = build_parser().parse_args(argv)
    session = _open_session(settings or Settings())
    try:
        if args.command == "list":
            return cmd_list(session, args)
        if args.command == "show":
            return cmd_show(session, args)
        if args.command == "hide":
            return _set_hidden(session, args.id, True)
        return _set_hidden(session, args.id, False)
    finally:
        session.close()


if __name__ == "__main__":
    raise SystemExit(main())
