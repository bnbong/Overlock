"""리더보드 SQL 쿼리 회귀 테스트 (B-2 DoS 방어).

전체 스캔 + Python dedup 을 윈도 함수(row_number)로 SQL 에 내렸다. 순위 결정성이
바뀌면 안 되므로, 기존 파이썬 dedup 참조 구현을 테스트 안에 재현해 신 구현과
행·순서·rank 가 완전히 일치함을 검증한다. 성능 스모크로 LIMIT 이 SQL 단계에서
적용됨(반환 행 수 제한)도 확인한다.
"""

from __future__ import annotations

from sqlalchemy import select

from app.models import Run
from app.routes import (
    _LEADERBOARD_ORDER,
    _leaderboard_page,
    _leaderboard_total,
    _player_rank,
)

# (player_name, difficulty, final_time_ms, accuracy, cuts, off_seam_ms, perfect_rate)
# 동률 · 다중 제출 · 다중 플레이어 · 다중 난이도 + 등급 스펙트럼(S/A/B/C/D). 정렬이
# 등급 우선(§14.1)으로 바뀌었으므로 perfect_rate 를 섞어 등급 티어를 다양하게 만든다.
# 특히 alice 의 normal 베스트는 이제 "더 느리지만 등급이 높은" 20000(S) 이다(18000 은 B).
_SEED = [
    ("alice", "normal", 18000, 90.0, 1, 500, 96.0),  # B (87.4)
    ("alice", "normal", 20000, 95.0, 0, 300, 98.0),  # S (96.2) → alice normal best(등급 우선)
    ("bob", "normal", 18000, 90.0, 1, 500, 96.0),  # alice 18000 과 메트릭 완전 동률 → id 타이브레이크
    ("carol", "normal", 18000, 95.0, 0, 200, 100.0),  # S (97.0)
    ("dave", "normal", 25000, 99.0, 0, 100, 100.0),  # S (99.4) 이지만 시간이 느림
    ("erin", "normal", 18000, 90.0, 2, 400, 80.0),  # B (76.0), cuts 더 많음
    ("frank", "normal", 18000, 90.0, 1, 400, 50.0),  # C (69.0)
    ("alice", "expert", 16000, 88.0, 1, 500, 90.0),  # B (83.8)
    ("gina", "expert", 22000, 91.0, 0, 200, 70.0),  # B (82.6)
    ("gina", "normal", 30000, 80.0, 3, 900, 40.0),  # D (49.0)
    ("bob", "expert", 17000, 92.0, 0, 100, 60.0),  # B (79.2)
]


def _reference_rows(session, track_id, difficulty):
    """구 구현 재현: 전체 정렬 후 Python 으로 플레이어당 첫 행만 남긴 dedup."""
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


def _seed_via_api(client, checksum):
    for name, difficulty, final, acc, cuts, off_seam, perfect in _SEED:
        resp = client.post(
            "/api/runs",
            json={
                "player_name": name,
                "track_id": "cotton_01",
                "difficulty": difficulty,
                "time_ms": final,
                "penalty_ms": 0,
                "final_time_ms": final,
                "accuracy": acc,
                "perfect_rate": perfect,
                "cuts": cuts,
                "off_seam_ms": off_seam,
                "game_version": "0.1.0",
                "track_checksum": checksum,
            },
        )
        assert resp.status_code == 201, resp.text


def test_sql_matches_python_dedup_rows_and_rank(client, cotton_checksum):
    _seed_via_api(client, cotton_checksum)
    session = client.app.state.sessionmaker()
    try:
        for difficulty in (None, "normal", "expert"):
            ref = _reference_rows(session, "cotton_01", difficulty)
            got = _leaderboard_page(session, "cotton_01", difficulty, limit=1000, offset=0)

            # 행·순서 완전 일치(고유 id 로 비교).
            assert [r.id for r in got] == [r.id for r in ref], difficulty
            # 총 개수 일치.
            assert _leaderboard_total(session, "cotton_01", difficulty) == len(ref), difficulty

            # 각 플레이어 rank(1-based) 가 참조 위치와 완전 일치.
            for index, run in enumerate(ref):
                assert (
                    _player_rank(session, "cotton_01", difficulty, run.player_name)
                    == index + 1
                ), (difficulty, run.player_name)

            # 페이지네이션도 참조 슬라이스와 일치.
            for limit, offset in ((2, 0), (3, 2), (5, 4), (100, 0)):
                page = _leaderboard_page(session, "cotton_01", difficulty, limit, offset)
                assert [r.id for r in page] == [
                    r.id for r in ref[offset : offset + limit]
                ], (difficulty, limit, offset)
    finally:
        session.close()


def test_http_leaderboard_ranks_match_reference(client, cotton_checksum):
    _seed_via_api(client, cotton_checksum)
    session = client.app.state.sessionmaker()
    try:
        ref = _reference_rows(session, "cotton_01", "normal")
    finally:
        session.close()

    resp = client.get(
        "/api/leaderboard",
        params={"track_id": "cotton_01", "difficulty": "normal", "limit": 500},
    )
    body = resp.json()
    assert body["count"] == len(ref)
    assert [e["run_id"] for e in body["entries"]] == [r.id for r in ref]
    assert [e["rank"] for e in body["entries"]] == list(range(1, len(ref) + 1))


def test_best_record_dedup_faster_replaces_slower(client, cotton_checksum):
    # 이슈 D 회귀: 리더보드는 플레이어당 최고 1건만 노출한다.
    # 같은 플레이어가 18000 → 17000(더 빠른 신기록) → 19000(더 느린 기록) 순으로
    # 제출해도, 리더보드에는 최고 기록(17000)만 단 1행 노출돼야 한다.
    #   - 더 빠른 신기록(17000)은 BEST 로 반영됨
    #   - 더 느리거나 더 최근인 기록(18000/19000)은 BEST 를 대체하지 못함
    def submit(final: int) -> None:
        resp = client.post(
            "/api/runs",
            json={
                "player_name": "sasha",
                "track_id": "cotton_01",
                "difficulty": "normal",
                "time_ms": final,
                "penalty_ms": 0,
                "final_time_ms": final,
                "accuracy": 90.0,
                "cuts": 0,
                "off_seam_ms": 100,
                "game_version": "0.1.0",
                "track_checksum": cotton_checksum,
            },
        )
        assert resp.status_code == 201, resp.text

    submit(18000)
    submit(17000)  # 더 빠른 신기록 → BEST 로 반영돼야 함
    submit(19000)  # 더 느리고 더 최근 → BEST 를 대체하면 안 됨

    resp = client.get(
        "/api/leaderboard",
        params={"track_id": "cotton_01", "difficulty": "normal", "limit": 500},
    )
    body = resp.json()
    entries = [e for e in body["entries"] if e["player_name"] == "sasha"]
    assert len(entries) == 1, "플레이어당 최고 1건만 노출돼야 한다"
    assert entries[0]["final_time_ms"] == 17000
    assert body["count"] == 1  # 서로 다른 플레이어 수(sasha 1명)


def test_leaderboard_sql_limit_smoke(client):
    # 수백 행 직접 시드 후 조회가 LIMIT 반영 행 수만 반환하는지(SQL 단계 LIMIT) 확인.
    n_players = 100
    runs_per = 5
    session = client.app.state.sessionmaker()
    try:
        for p in range(n_players):
            for k in range(runs_per):
                value = 20000 + p * 10 + k
                session.add(
                    Run(
                        player_name=f"perf{p:03d}",
                        track_id="cotton_01",
                        difficulty="normal",
                        time_ms=value,
                        penalty_ms=0,
                        final_time_ms=value,
                        accuracy=90.0,
                        cuts=0,
                        off_seam_ms=100,
                        game_version="0.1.0",
                        track_checksum="sha256:" + "0" * 64,
                        replay_hash=None,
                        verification_status="unverified",
                        created_at=f"t{p * runs_per + k:06d}",
                    )
                )
        session.commit()
    finally:
        session.close()

    resp = client.get(
        "/api/leaderboard", params={"track_id": "cotton_01", "limit": 10}
    )
    body = resp.json()
    assert body["count"] == n_players  # 서로 다른 player 수(전체)
    assert body["limit"] == 10
    assert len(body["entries"]) == 10  # SQL LIMIT 반영: 페이지만 반환
    # 순위 순 상위 10명이 맞는지(가장 빠른 final_time 순).
    assert [e["rank"] for e in body["entries"]] == list(range(1, 11))
