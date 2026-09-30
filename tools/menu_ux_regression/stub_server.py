"""메뉴 UX 회귀 검사용 지연 리더보드 스텁 서버(127.0.0.1 전용, 운영 서버와 무관).

GET /api/health                  -> {"status": "ok", "version": "stub"}
GET /api/leaderboard?track_id=.. -> 계획 큐의 다음 항목(지연 초·HTTP 코드)대로 응답한다.
    본문 entries 의 player_name 은 "<track_id>#<요청 순번>" 이라 어느 요청의 응답인지 화면에서 구분된다.
GET /__plan?delays=1.5,1.0&codes=200,500&count=12 -> 다음 요청들의 지연·코드·기록 수 큐를 정한다.
GET /__log                       -> 지금까지 받은 리더보드 요청 [{"n", "track_id", "difficulty"}].

사용: python3 stub_server.py <port>
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Lock()
PLAN = []  # [{"delay": float, "code": int, "count": int}]
LOG = []
SEQ = [0]


def _entries(track_id, n, count):
    out = []
    for i in range(count):
        out.append(
            {
                "rank": i + 1,
                "player_name": "%s#%d" % (track_id, n) if i == 0 else "%s#%d-%d" % (track_id, n, i),
                "final_time_ms": 61000 + i * 731,
                "accuracy": 97.5 - i,
                "perfect_rate": 90.0 - i,
                "cuts": i % 3,
                "grade": "S" if i == 0 else "A",
            }
        )
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/api/health":
            self._send(200, {"status": "ok", "version": "stub"})
            return
        if url.path == "/__plan":
            delays = [float(x) for x in q.get("delays", [""])[0].split(",") if x]
            codes = [int(x) for x in q.get("codes", [""])[0].split(",") if x]
            count = int(q.get("count", ["3"])[0])
            n = max(len(delays), len(codes))
            with LOCK:
                PLAN.clear()
                for i in range(n):
                    PLAN.append(
                        {
                            "delay": delays[i] if i < len(delays) else 0.0,
                            "code": codes[i] if i < len(codes) else 200,
                            "count": count,
                        }
                    )
            self._send(200, {"planned": n})
            return
        if url.path == "/__log":
            with LOCK:
                self._send(200, {"requests": list(LOG)})
            return
        if url.path == "/api/leaderboard":
            track_id = q.get("track_id", [""])[0]
            with LOCK:
                SEQ[0] += 1
                n = SEQ[0]
                step = PLAN.pop(0) if PLAN else {"delay": 0.0, "code": 200, "count": 3}
                LOG.append({"n": n, "track_id": track_id, "difficulty": q.get("difficulty", [""])[0]})
            time.sleep(step["delay"])
            if step["code"] != 200:
                self._send(step["code"], {"detail": "stub error"})
                return
            try:
                self._send(200, {"entries": _entries(track_id, n, step["count"])})
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self._send(404, {"detail": "not found"})


def main():
    port = int(sys.argv[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
