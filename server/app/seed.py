"""공식 트랙 시드 (기획서 §13.2 체크섬 검증, §18 물리 하한 계산).

서버 기동 시 ``server/app/tracks/`` 스냅샷(= game/tracks/official 바이트 복사본)에서
트랙 5종을 등록한다. 체크섬은 **트랙 JSON 파일의 원본 바이트** SHA-256 이며, 그대로
클라이언트가 자기 번들의 같은 파일 바이트로 계산해 맞출 수 있다(README 참조).
"""

from __future__ import annotations

import hashlib
import json
import math
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Track

CHECKSUM_PREFIX = "sha256:"


def compute_file_checksum(path: Path) -> str:
    """트랙 JSON 파일 바이트의 SHA-256 을 "sha256:<hex>" 로 반환.

    클라이언트는 자신이 번들한 동일 트랙 파일의 **원본 바이트**에 같은 계산을 적용하면
    같은 값을 얻는다. 포매팅/개행이 한 바이트라도 다르면 값이 달라지므로, 서버 스냅샷은
    game/tracks/official 의 바이트를 그대로 복사해 둔다.
    """
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return f"{CHECKSUM_PREFIX}{digest}"


def compute_min_final_time_ms(length_px: float, max_speed_px_s: float) -> int:
    """물리적으로 가능한 최소 완주 시간(ms) = floor((length / max_speed) * 1000).

    최고속도(300px/s, §7.2)로 트랙 전체를 달렸을 때의 시간. 이보다 빠른 기록은
    물리적으로 불가능하므로 거부한다(§18). floor 로 경계를 살짝 관대하게 둔다.
    """
    if max_speed_px_s <= 0:
        return 0
    return int(math.floor((length_px / max_speed_px_s) * 1000.0))


def _iter_snapshot_tracks(tracks_dir: Path) -> list[Path]:
    """스냅샷 디렉토리의 트랙 JSON 경로 목록. index.json 순서를 우선한다."""
    manifest = tracks_dir / "index.json"
    ordered: list[Path] = []
    seen: set[str] = set()
    if manifest.is_file():
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
            for entry in data.get("tracks", []):
                tid = str(entry.get("track_id", ""))
                candidate = tracks_dir / f"{tid}.json"
                if tid and candidate.is_file():
                    ordered.append(candidate)
                    seen.add(candidate.name)
        except (json.JSONDecodeError, OSError):
            pass
    # 매니페스트에 없는 트랙 파일도 누락 없이 등록(index.json 제외).
    for path in sorted(tracks_dir.glob("*.json")):
        if path.name == "index.json" or path.name in seen:
            continue
        ordered.append(path)
    return ordered


def seed_tracks(session: Session, tracks_dir: Path, max_speed_px_s: float) -> int:
    """스냅샷 트랙을 tracks 테이블에 upsert. 등록/갱신된 트랙 수를 반환한다.

    기존 행이 있으면 checksum/name/난이도/길이/하한을 갱신하고 created_at 은 보존한다.
    """
    now = datetime.now(timezone.utc).isoformat()
    count = 0
    for path in _iter_snapshot_tracks(tracks_dir):
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        track_id = str(raw.get("track_id", "")) or path.stem
        checksum = compute_file_checksum(path)
        length_px = int(raw.get("length", 0) or 0)
        min_final_time_ms = compute_min_final_time_ms(length_px, max_speed_px_s)

        existing = session.get(Track, track_id)
        if existing is None:
            session.add(
                Track(
                    id=track_id,
                    name=str(raw.get("name", track_id)),
                    difficulty=str(raw.get("difficulty", "normal")),
                    checksum=checksum,
                    length_px=length_px,
                    min_final_time_ms=min_final_time_ms,
                    created_at=now,
                )
            )
        else:
            existing.name = str(raw.get("name", track_id))
            existing.difficulty = str(raw.get("difficulty", "normal"))
            existing.checksum = checksum
            existing.length_px = length_px
            existing.min_final_time_ms = min_final_time_ms
        count += 1
    session.commit()
    return count


def list_track_ids(session: Session) -> list[str]:
    return list(session.scalars(select(Track.id)).all())
