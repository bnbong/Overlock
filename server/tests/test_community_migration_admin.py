"""신규 테이블 도입 시 기존 데이터 보존 + 운영자 CLI(비공개 처리) 테스트."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, text

from app import community_admin
from app.main import create_app
from app.models import Run, Track
from app.seed import seed_tracks
from conftest import TRACKS_DIR, make_settings

URL = "/api/community/tracks"


def test_existing_db_keeps_official_tracks_and_runs(tmp_path, make_community_payload):
    """기존 스키마(tracks/runs 만)로 만든 DB 에 앱을 다시 띄워도 기존 행이 그대로 남는다."""
    db_path = tmp_path / "test.db"
    engine = create_engine(f"sqlite:///{db_path}")
    # 기존 스키마만 생성(community_tracks 없음) + 공식 트랙 시드 + 기록 1건.
    Track.metadata.create_all(engine, tables=[Track.__table__, Run.__table__])
    from sqlalchemy.orm import Session

    with Session(engine) as session:
        seed_tracks(session, TRACKS_DIR, 300.0, 0.75)
        cotton = session.get(Track, "cotton_01")
        session.add(
            Run(
                player_name="veteran",
                track_id="cotton_01",
                difficulty="normal",
                time_ms=40000,
                penalty_ms=0,
                final_time_ms=40000,
                accuracy=90.0,
                perfect_rate=50.0,
                cuts=0,
                off_seam_ms=0,
                game_version="1.0.0",
                track_checksum=cotton.checksum,
                verification_status="unverified",
                created_at=datetime.now(timezone.utc).isoformat(),
            )
        )
        session.commit()
        before_tracks = session.execute(
            text("SELECT id, checksum, created_at FROM tracks ORDER BY id")
        ).all()
        before_runs = session.execute(text("SELECT * FROM runs ORDER BY id")).all()
    before_run_cols = [c["name"] for c in inspect(engine).get_columns("runs")]
    before_track_cols = [c["name"] for c in inspect(engine).get_columns("tracks")]
    assert "community_tracks" not in inspect(engine).get_table_names()
    engine.dispose()

    # 새 코드로 앱 기동 → create_all 이 community_tracks 만 추가한다.
    app = create_app(make_settings(tmp_path))
    with TestClient(app) as client:
        insp = inspect(app.state.engine)
        assert "community_tracks" in insp.get_table_names()
        assert [c["name"] for c in insp.get_columns("runs")] == before_run_cols
        assert [c["name"] for c in insp.get_columns("tracks")] == before_track_cols

        with app.state.engine.connect() as conn:
            after_tracks = conn.execute(
                text("SELECT id, checksum, created_at FROM tracks ORDER BY id")
            ).all()
            after_runs = conn.execute(text("SELECT * FROM runs ORDER BY id")).all()
        assert after_tracks == before_tracks
        assert after_runs == before_runs

        # 기존 API 동작 + 신규 API 동작.
        lb = client.get("/api/leaderboard", params={"track_id": "cotton_01"}).json()
        assert [e["player_name"] for e in lb["entries"]] == ["veteran"]
        assert client.get(f"/api/runs/{before_runs[0].id}").status_code == 200
        assert client.post(URL, json=make_community_payload()).status_code == 201
        assert client.get(URL).json()["total"] == 1

    # 두 번째 기동(테이블이 이미 있음)도 데이터를 보존한다.
    app2 = create_app(make_settings(tmp_path))
    with TestClient(app2) as client2:
        assert client2.get(URL).json()["total"] == 1
        lb = client2.get("/api/leaderboard", params={"track_id": "cotton_01"}).json()
        assert lb["count"] == 1


def test_admin_cli_hide_and_unhide(tmp_path, make_client, make_community_payload, capsys):
    client = make_client()
    settings = client.app.state.settings
    created = client.post(URL, json=make_community_payload(title="Spam")).json()
    other = client.post(URL, json=make_community_payload(title="Fine")).json()

    assert community_admin.main(["list"], settings=settings) == 0
    out = capsys.readouterr().out
    assert created["id"] in out and other["id"] in out
    assert created["delete_token"] not in out  # 토큰은 서버에도 없다

    assert community_admin.main(["hide", created["id"]], settings=settings) == 0
    assert client.get(f"{URL}/{created['id']}").status_code == 404
    listing = client.get(URL).json()
    assert [it["id"] for it in listing["items"]] == [other["id"]]
    # 비공개 처리된 게시물은 게시자 토큰으로도 다시 삭제할 수 없다(이미 삭제 상태 → 404).
    r = client.delete(
        f"{URL}/{created['id']}", headers={"Authorization": f"Bearer {created['delete_token']}"}
    )
    assert r.status_code == 404

    capsys.readouterr()
    community_admin.main(["list"], settings=settings)
    assert created["id"] not in capsys.readouterr().out
    community_admin.main(["list", "--all"], settings=settings)
    out = capsys.readouterr().out
    assert created["id"] in out and "hidden" in out

    assert community_admin.main(["hide", created["id"]], settings=settings) == 0  # 멱등
    assert community_admin.main(["unhide", created["id"]], settings=settings) == 0
    assert client.get(f"{URL}/{created['id']}").status_code == 200

    assert community_admin.main(["show", created["id"]], settings=settings) == 0
    out = capsys.readouterr().out
    assert "delete_token" not in out
    assert community_admin.main(["hide", "no-such-id"], settings=settings) == 1
