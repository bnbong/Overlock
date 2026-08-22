"""인메모리 레이트리밋 (기획서 §18: IP당 분당 N회).

단순 슬라이딩 윈도(최근 60초 요청 타임스탬프 보관)로 구현한다. 단일 프로세스
기준이며, 여러 워커/인스턴스로 확장하면 Redis 등 공유 저장소가 필요하다(README 참조).
POST /api/runs 에만 적용한다(읽기 엔드포인트는 제한하지 않는다).
"""

from __future__ import annotations

import threading
import time
from collections import defaultdict, deque

WINDOW_SECONDS = 60.0


class RateLimiter:
    """IP별 슬라이딩 윈도 카운터. 스레드 안전."""

    def __init__(self, per_minute: int) -> None:
        self.per_minute = per_minute
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str, now: float | None = None) -> bool:
        """key(보통 IP)의 요청을 허용하면 True, 한도 초과면 False.

        per_minute <= 0 이면 제한을 끈다(항상 허용).
        """
        if self.per_minute <= 0:
            return True
        current = time.monotonic() if now is None else now
        cutoff = current - WINDOW_SECONDS
        with self._lock:
            bucket = self._hits[key]
            while bucket and bucket[0] <= cutoff:
                bucket.popleft()
            if len(bucket) >= self.per_minute:
                return False
            bucket.append(current)
            return True

    def reset(self) -> None:
        """전체 상태 초기화(테스트/재시작용)."""
        with self._lock:
            self._hits.clear()
