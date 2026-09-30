"""인메모리 레이트리밋 (기획서 §18: IP당 분당 N회).

단순 슬라이딩 윈도(최근 window_seconds 초 요청 타임스탬프 보관)로 구현한다. 단일
프로세스 기준이며, 여러 워커/인스턴스로 확장하면 프록시 공통 제한 등 공유 수단이
필요하다(README 참조). 인스턴스마다 버킷이 독립이라 기록 제출(POST /api/runs)과
공유 허브(게시·조회·삭제)는 서로 다른 인스턴스를 써서 버킷을 분리한다.
"""

from __future__ import annotations

import threading
import time
from collections import defaultdict, deque

WINDOW_SECONDS = 60.0


# 오래 조용한 키(IP)를 정리하는 주기(allow 호출 수). 공개 조회 엔드포인트처럼 IP 가
# 계속 늘어나는 경우 빈 버킷이 무한히 쌓이지 않게 한다. 판정 결과에는 영향이 없다.
_SWEEP_EVERY = 1024


class RateLimiter:
    """IP별 슬라이딩 윈도 카운터. 스레드 안전.

    per_minute 는 "윈도당 허용 횟수"다(역사적 이름 유지). 기본 윈도는 60초이며,
    일일 제한처럼 다른 길이가 필요하면 window_seconds 를 지정한다.
    """

    def __init__(self, per_minute: int, window_seconds: float = WINDOW_SECONDS) -> None:
        self.per_minute = per_minute
        self.window_seconds = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()
        self._calls = 0

    def allow(self, key: str, now: float | None = None) -> bool:
        """key(보통 IP)의 요청을 허용하면 True, 한도 초과면 False.

        per_minute <= 0 이면 제한을 끈다(항상 허용).
        """
        if self.per_minute <= 0:
            return True
        current = time.monotonic() if now is None else now
        cutoff = current - self.window_seconds
        with self._lock:
            self._calls += 1
            if self._calls % _SWEEP_EVERY == 0:
                self._sweep(cutoff)
            bucket = self._hits[key]
            while bucket and bucket[0] <= cutoff:
                bucket.popleft()
            if len(bucket) >= self.per_minute:
                return False
            bucket.append(current)
            return True

    def _sweep(self, cutoff: float) -> None:
        """마지막 요청이 윈도 밖인 키를 제거한다(락 보유 상태에서 호출)."""
        stale = [k for k, b in self._hits.items() if not b or b[-1] <= cutoff]
        for k in stale:
            del self._hits[k]

    def reset(self) -> None:
        """전체 상태 초기화(테스트/재시작용)."""
        with self._lock:
            self._hits.clear()
