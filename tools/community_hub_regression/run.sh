#!/usr/bin/env bash
# 공유 허브 클라이언트(CommunityTrackClient·TrackLoader 허브 가져오기·CommunityStore·허브 화면) 회귀 검사 실행기.
# 저장소의 game/ 을 임시 디렉터리에 복사한 사본에서만 실행하므로 저장소와 실제 사용자 기록
# (~/Library/Application Support/Godot/app_userdata/Overlock/)을 건드리지 않는다.
# 사본은 실행마다 고유한 custom user dir(overlock_community_hub_regression_<접미사>_<PID>)을 쓰고,
# 종료 시 이 실행이 만든 디렉터리만 지운다.
# 서버 연동 항목을 위해 임시 SQLite DB 로 로컬 서버 두 개(게시 제한 해제 / 게시 분당 1회)와 응답하지 않는
# 소켓 서버(타임아웃 확인용)를 127.0.0.1 의 빈 포트에 띄우고, 끝나면 모두 종료한다.
# 환경변수: GODOT(엔진 경로), SERVER_PYTHON(uvicorn 이 설치된 파이썬, 기본: 원본 체크아웃의 server/.venv),
#   COMMUNITY_HUB_TMP(임시 작업 디렉터리 상위 경로), COMMUNITY_HUB_TIMEOUT(검사 제한 초, 기본 300),
#   IMPORT_TIMEOUT(headless import 제한 초, 기본 300).
# 종료 코드가 0이어도 "community hub regression: N passed, 0 failed" 요약 줄이 없으면 실패(3)로 본다.
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SERVER_DIR="$REPO/server"
SERVER_PYTHON="${SERVER_PYTHON:-/Users/bnbong/Documents/WorkstationFiles/programming/overlock/server/.venv/bin/python}"
TMP_BASE="${COMMUNITY_HUB_TMP:-${TMPDIR:-/tmp}}"
CHECK_LIMIT="${COMMUNITY_HUB_TIMEOUT:-300}"
IMPORT_LIMIT="${IMPORT_TIMEOUT:-300}"
for v in "$CHECK_LIMIT" "$IMPORT_LIMIT"; do
	if ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
		echo "제한 시간은 1 이상의 정수(초)여야 합니다: '$v'" >&2
		exit 2
	fi
done
if [ ! -x "$GODOT" ]; then
	echo "Godot 실행 파일을 찾을 수 없습니다: $GODOT (환경변수 GODOT 로 지정)" >&2
	exit 2
fi
if [ ! -x "$SERVER_PYTHON" ]; then
	echo "서버 파이썬을 찾을 수 없습니다: $SERVER_PYTHON (환경변수 SERVER_PYTHON 으로 지정)" >&2
	exit 2
fi
if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
	echo "HOME 이 비어 있거나 / 입니다" >&2
	exit 2
fi
case "$(uname -s)" in
	Darwin) USERDATA_ROOT="$HOME/Library/Application Support" ;;
	*) USERDATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}" ;;
esac

GODOT_PID=""
BG_PIDS=()
USERDIR_NAME=""
USERDATA_DIR=""
USERDATA_OWNED=0

stop_pid() {
	local pid="$1"
	[ -n "$pid" ] || return 0
	if kill -0 "$pid" 2>/dev/null; then
		kill -TERM "$pid" 2>/dev/null || true
		local i=0
		while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
			sleep 0.1
			i=$((i + 1))
		done
		kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
	fi
	wait "$pid" 2>/dev/null || true
}

remove_userdata() {
	[ "$USERDATA_OWNED" = "1" ] || return 0
	[[ "$USERDIR_NAME" =~ ^overlock_community_hub_regression_[A-Za-z0-9]+_[0-9]+$ ]] || return 0
	[ "$USERDATA_DIR" = "$USERDATA_ROOT/$USERDIR_NAME" ] || return 0
	[ -d "$USERDATA_DIR" ] && [ ! -L "$USERDATA_DIR" ] || return 0
	chmod -R u+w "$USERDATA_DIR" 2>/dev/null || true
	rm -rf -- "$USERDATA_DIR"
}

cleanup() {
	stop_pid "$GODOT_PID"
	GODOT_PID=""
	for p in "${BG_PIDS[@]:-}"; do
		stop_pid "$p"
	done
	remove_userdata
	if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
		rm -rf -- "$WORK"
	fi
}

mkdir -p "$TMP_BASE"
WORK="$(mktemp -d "$TMP_BASE/community_hub_regression.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PROJ="$WORK/game"
USERDIR_NAME="overlock_community_hub_regression_${WORK##*.}_$$"
USERDATA_DIR="$USERDATA_ROOT/$USERDIR_NAME"
if [ -e "$USERDATA_DIR" ] || [ -L "$USERDATA_DIR" ]; then
	echo "user data 디렉터리가 이미 있습니다(건드리지 않음): $USERDATA_DIR" >&2
	exit 2
fi
USERDATA_OWNED=1

# 1) game/ 사본(.godot 캐시 제외) + 격리 user dir 설정 + 검사 스크립트·fixture 복사.
mkdir -p "$PROJ"
(cd "$REPO/game" && tar --exclude='./.godot' -cf - .) | (cd "$PROJ" && tar -xf -)
tr -d '\r' <"$PROJ/project.godot" | awk -v userdir="$USERDIR_NAME" '
	{ print }
	$0 == "[application]" && !done {
		print "config/use_custom_user_dir=true"
		print "config/custom_user_dir_name=\"" userdir "\""
		done = 1
	}
	END { if (!done) exit 1 }
' >"$PROJ/project.godot.new" || {
	echo "project.godot 에 [application] 섹션이 없습니다" >&2
	exit 2
}
mv "$PROJ/project.godot.new" "$PROJ/project.godot"
mkdir -p "$PROJ/community_hub_regression"
cp "$HERE/check.gd" "$HERE/check_base.gd" "$HERE/check_server.gd" "$HERE/check_fixes.gd" "$HERE/check.tscn" \
	"$PROJ/community_hub_regression/"
FIXTURES="$WORK/fixtures"
mkdir -p "$FIXTURES"
cp "$SERVER_DIR/tests/fixtures/community_tracks/"*.json "$FIXTURES/"

# 2) 로컬 서버(임시 DB)와 무응답 소켓 서버.
free_port() {
	"$SERVER_PYTHON" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}
start_server() { # start_server <port> <db> <per_minute> <log>
	(cd "$SERVER_DIR" && OVERLOCK_DB_URL="sqlite:///$2" OVERLOCK_COMMUNITY_POST_PER_MINUTE="$3" \
		OVERLOCK_COMMUNITY_POST_PER_DAY=0 \
		exec "$SERVER_PYTHON" -m uvicorn app.main:app --host 127.0.0.1 --port "$1" --log-level warning) \
		>"$4" 2>&1 &
	BG_PIDS+=($!)
}
wait_health() { # wait_health <port>
	local i=0
	while [ "$i" -lt 100 ]; do
		if curl -fsS "http://127.0.0.1:$1/api/health" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.2
		i=$((i + 1))
	done
	echo "서버가 127.0.0.1:$1 에서 뜨지 않았습니다" >&2
	return 1
}
PORT_MAIN="$(free_port)"
PORT_LIMITED="$(free_port)"
PORT_SILENT="$(free_port)"
start_server "$PORT_MAIN" "$WORK/hub_main.db" 0 "$WORK/server_main.log"
start_server "$PORT_LIMITED" "$WORK/hub_limited.db" 1 "$WORK/server_limited.log"
"$SERVER_PYTHON" -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
conns = []
while True:
    c, _ = s.accept(); conns.append(c)  # 받기만 하고 응답하지 않는다
' "$PORT_SILENT" >"$WORK/silent.log" 2>&1 &
BG_PIDS+=($!)
wait_health "$PORT_MAIN"
wait_health "$PORT_LIMITED"

# 제한 시간 안에서 Godot 실행: run_godot <제한 초> <log> <Godot 인자...>. 결과는 RUN_CODE(시간 초과 124).
RUN_CODE=0
run_godot() {
	local limit="$1" log="$2"
	shift 2
	"$GODOT" "$@" >"$log" 2>&1 &
	GODOT_PID=$!
	local start=$SECONDS
	while kill -0 "$GODOT_PID" 2>/dev/null; do
		if [ $((SECONDS - start)) -ge "$limit" ]; then
			stop_pid "$GODOT_PID"
			GODOT_PID=""
			echo "시간 초과: ${limit}초 안에 끝나지 않아 Godot 를 종료했습니다: $*" >&2
			RUN_CODE=124
			return 0
		fi
		sleep 1
	done
	RUN_CODE=0
	wait "$GODOT_PID" || RUN_CODE=$?
	GODOT_PID=""
}

run_godot "$IMPORT_LIMIT" "$WORK/import.log" --headless --path "$PROJ" --import
if [ "$RUN_CODE" -ne 0 ]; then
	echo "import 실패(exit=$RUN_CODE):" >&2
	cat "$WORK/import.log" >&2
	exit 2
fi
run_godot "$CHECK_LIMIT" "$WORK/check.log" --headless --path "$PROJ" \
	res://community_hub_regression/check.tscn -- \
	"--fixtures=$FIXTURES" "--api=http://127.0.0.1:$PORT_MAIN" \
	"--api-limited=http://127.0.0.1:$PORT_LIMITED" "--api-silent=http://127.0.0.1:$PORT_SILENT"
cat "$WORK/check.log"
code=$RUN_CODE
if [ "$code" -eq 0 ] && ! grep -Eq "^community hub regression: [0-9]+ passed, 0 failed$" "$WORK/check.log"; then
	echo "'community hub regression: N passed, 0 failed' 요약 줄이 출력되지 않았습니다" >&2
	code=3
fi
# 로그에 삭제 토큰이 찍히지 않았는지: 검사 뒤 남은 게시 기록의 토큰을 Godot 로그에서 찾는다.
PUB="$USERDATA_DIR/community/published.json"
if [ -f "$PUB" ]; then
	leaked=0
	while IFS= read -r tok; do
		[ -n "$tok" ] || continue
		if grep -Fq -- "$tok" "$WORK/check.log"; then
			leaked=1
		fi
	done < <("$SERVER_PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(v["delete_token"]) for v in d.get("posts",{}).values()]' "$PUB")
	# 저장하지 못해 메모리에만 있던 토큰(검사가 user dir 에 적어 둔 목록)도 같은 방식으로 찾는다.
	MEM="$USERDATA_DIR/regression_unsaved_tokens.txt"
	mem_count=0
	if [ -f "$MEM" ]; then
		while IFS= read -r tok; do
			[ -n "$tok" ] || continue
			mem_count=$((mem_count + 1))
			if grep -Fq -- "$tok" "$WORK/check.log"; then
				leaked=1
			fi
		done <"$MEM"
	fi
	if [ "$leaked" -eq 1 ]; then
		echo "FAIL: 삭제 토큰이 Godot 로그에 출력되었습니다" >&2
		code=4
	else
		echo "token log check: no delete token in Godot log ($(grep -c delete_token "$PUB" || true) stored, $mem_count in-memory)"
	fi
else
	echo "FAIL: published.json 이 없어 토큰 로그 검사를 하지 못했습니다" >&2
	[ "$code" -eq 0 ] && code=5
fi
echo "community hub check exit=$code"
exit "$code"
