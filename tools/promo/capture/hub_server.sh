#!/usr/bin/env bash
# 홍보 촬영용 공유 허브 로컬 서버. 저장소 server/ 를 임시 SQLite DB 로 127.0.0.1 의 빈 포트에 띄우고,
# server/tests/fixtures/community_tracks 의 수락 사례 3개를 촬영용 데모 게시물로 올린다.
# 운영 서버에는 요청하지 않는다. 기동 방식은 tools/community_hub_regression/run.sh 와 같다.
#
# usage: hub_server.sh start <작업 디렉터리>   → <작업>/hub.port, hub.pid, hub.db, hub.log
#        hub_server.sh stop  <작업 디렉터리>
# 환경변수: SERVER_PYTHON(uvicorn 이 설치된 파이썬, 기본: 원본 체크아웃의 server/.venv)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SERVER_DIR="$REPO/server"
SERVER_PYTHON="${SERVER_PYTHON:-$REPO/server/.venv/bin/python}"
CMD="${1:?start|stop}"
WORK="${2:?작업 디렉터리}"
mkdir -p "$WORK"

if [ "$CMD" = "stop" ]; then
	if [ -f "$WORK/hub.pid" ]; then
		kill "$(cat "$WORK/hub.pid")" 2>/dev/null || true
		rm -f "$WORK/hub.pid"
	fi
	echo "hub server stopped"
	exit 0
fi

PORT="$("$SERVER_PYTHON" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
rm -f "$WORK/hub.db"
(cd "$SERVER_DIR" && OVERLOCK_DB_URL="sqlite:///$WORK/hub.db" OVERLOCK_COMMUNITY_POST_PER_MINUTE=0 \
	OVERLOCK_COMMUNITY_POST_PER_DAY=0 \
	exec "$SERVER_PYTHON" -m uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --log-level warning) \
	>"$WORK/hub.log" 2>&1 &
echo $! >"$WORK/hub.pid"
echo "$PORT" >"$WORK/hub.port"
for _ in $(seq 100); do
	curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
	sleep 0.2
done
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null

# 데모 게시물(촬영용 가상 작성자). 목록은 최신순이므로 마지막에 올린 게시물이 첫 줄에 온다.
"$SERVER_PYTHON" - "$REPO/server/tests/fixtures/community_tracks" "$PORT" <<'PY'
import json, sys, urllib.request
fx, port = sys.argv[1], sys.argv[2]
posts = [
    ("accept_stadium_expert.json", "트랙 경기장 한 바퀴", "바늘손", "긴 직선과 반원 두 개로 만든 고속 코스입니다.",
     {"fabric": "denim"}, [(900, "thimble"), (2100, "autopilot")]),
    ("accept_sparse_s_curve.json", "느긋한 S자 산책", "솔기장인", "완만한 S자 곡선입니다. 처음 달리는 분께 추천합니다.",
     {"fabric": "silk"}, [(700, "thimble")]),
    ("accept_heart_01_polyline.json", "하트 한 바퀴 연습", "실밥요정",
     "하트 윤곽을 한 바퀴 도는 연습 코스입니다. 아래쪽 꼭짓점은 드리프트로 돌아 보세요.",
     {}, [(1450, "thimble")]),
]
for fn, title, author, desc, patch, items in posts:
    tr = json.load(open(f"{fx}/{fn}"))["track"]
    tr.update(patch)
    tr["items"] = [{"s": float(s), "type": t, "lat": 0.0} for s, t in items]
    body = json.dumps({"title": title, "author_name": author, "description": desc, "track": tr}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/community/tracks", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as r:
        d = json.load(r)
        print("posted", d["id"], d["title"], d.get("length"))
PY
echo "hub server on http://127.0.0.1:$PORT (pid $(cat "$WORK/hub.pid"))"
