"""init_db 동시 기동 경합 테스트.

create_all 은 "테이블이 있는지 확인 → CREATE" 를 따로 수행하므로, 두 프로세스가 같은 DB 로 동시에
기동하면 늦은 쪽이 "table ... already exists" 로 실패할 수 있다. init_db 는 이 경우 한 번 더 실행해
이미 만들어진 테이블을 건너뛴다.
"""

from __future__ import annotations

import threading

import pytest
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from app import database
from app.main import create_app
from app.models import Base, Run, Track
from app.seed import seed_tracks
from conftest import TRACKS_DIR, make_settings


def test_init_db_retries_once_after_already_exists(tmp_path, monkeypatch):
    engine = create_engine(f"sqlite:///{tmp_path / 'race.db'}")
    real_create_all = Base.metadata.create_all
    calls: list[int] = []

    def flaky_create_all(bind, *args, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            # 다른 프로세스가 먼저 만든 상황: 실제로 테이블을 만든 뒤 "already exists" 를 낸다.
            real_create_all(bind, *args, **kwargs)
            raise OperationalError("CREATE TABLE tracks", {}, Exception("table tracks already exists"))
        return real_create_all(bind, *args, **kwargs)

    monkeypatch.setattr(Base.metadata, "create_all", flaky_create_all)
    database.init_db(engine)
    assert len(calls) == 2
    assert {"tracks", "runs", "community_tracks"} <= set(inspect(engine).get_table_names())
    engine.dispose()


def test_init_db_reraises_persistent_error(tmp_path, monkeypatch):
    engine = create_engine(f"sqlite:///{tmp_path / 'race.db'}")

    def broken_create_all(bind, *args, **kwargs):
        raise OperationalError("CREATE TABLE tracks", {}, Exception("disk I/O error"))

    monkeypatch.setattr(Base.metadata, "create_all", broken_create_all)
    with pytest.raises(OperationalError):
        database.init_db(engine)
    engine.dispose()


def test_two_servers_starting_together(tmp_path):
    """기존 DB(tracks/runs 만 있음)에 서버 두 개가 동시에 기동해 community_tracks 를 함께 만들려는
    상황을 스레드 2개로 모사한다. 둘 다 오류 없이 떠야 한다."""
    engine = create_engine(f"sqlite:///{tmp_path / 'test.db'}")
    Base.metadata.create_all(engine, tables=[Track.__table__, Run.__table__])
    # 운영 DB 처럼 공식 트랙이 이미 시드된 상태(빈 DB 의 최초 동시 시드는 이 테스트 범위 밖).
    with Session(engine) as session:
        seed_tracks(session, TRACKS_DIR, 300.0, 0.75)
    engine.dispose()

    barrier = threading.Barrier(2)
    errors: list[BaseException] = []
    apps = []

    def boot() -> None:
        barrier.wait()
        try:
            apps.append(create_app(make_settings(tmp_path)))
        except BaseException as exc:  # noqa: BLE001 - 스레드 예외를 본문에서 검사한다
            errors.append(exc)

    threads = [threading.Thread(target=boot) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    assert errors == []
    assert len(apps) == 2
    with apps[0].state.engine.connect() as conn:
        assert conn.execute(text("SELECT COUNT(*) FROM tracks")).scalar_one() > 0
    assert "community_tracks" in inspect(apps[0].state.engine).get_table_names()
    for app in apps:
        app.state.engine.dispose()
