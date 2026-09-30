#!/usr/bin/env bash
# 메뉴 UX 회귀 검사 실행기(v2.2.1 P1: 메뉴 터치 배치, 설정 자동 저장·닉네임 저장/취소, 리더보드 오래된 응답).
# 저장소의 game/ 을 임시 디렉터리에 복사한 사본에서만 실행하므로 저장소와 실제 사용자 기록
# (~/Library/Application Support/Godot/app_userdata/Overlock/)을 건드리지 않는다. 사본은 실행마다 고유한
# custom user dir(overlock_menu_ux_regression_<접미사>_<PID>)을 쓰고, 종료 시 이 실행이 만든 디렉터리만 지운다.
# 리더보드 항목은 127.0.0.1 의 빈 포트에 띄운 지연 스텁(stub_server.py)에만 요청한다(운영 서버 요청 없음).
#
# 순서: headless import → 데스크톱 검사(배치 불변·설정·닉네임·리더보드) → `-- --touch-controls` 터치 배치 검사.
# 데스크톱 헤드리스 모사이며 실제 기기 터치·웹 브라우저 검증이 아니다.
# 환경변수:
#   GODOT(엔진 경로), MENU_UX_TMP(임시 작업 디렉터리 상위 경로), MENU_UX_TIMEOUT(검사 제한 초, 기본 300),
#   IMPORT_TIMEOUT(import 제한 초, 기본 300), GAME_DIR(검사할 game 디렉터리, 기본 저장소 game/),
#   ONLY(한 구역만: touch 는 터치 배치 검사만, layout|prefs|nick|lb 는 데스크톱 검사의 그 구역만),
#   DUMP(경로: 데스크톱 버튼 사각형을 이 JSON 으로 뽑고 끝낸다. 기준 갱신용),
#   CAPTURE_OUT(디렉터리: 검사 뒤 창을 띄워 844x390·932x430 터치, 1280x720 데스크톱 캡처를 남긴다).
# 종료 코드가 0이어도 "menu ux regression (...): N passed, 0 failed" 요약 줄이 없으면 실패(3)로 본다.
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GAME_SRC="${GAME_DIR:-$REPO/game}"
TMP_BASE="${MENU_UX_TMP:-${TMPDIR:-/tmp}}"
CHECK_LIMIT="${MENU_UX_TIMEOUT:-300}"
IMPORT_LIMIT="${IMPORT_TIMEOUT:-300}"
ONLY="${ONLY:-}"
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
if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
	echo "HOME 이 비어 있거나 / 입니다" >&2
	exit 2
fi
case "$(uname -s)" in
	Darwin) USERDATA_ROOT="$HOME/Library/Application Support" ;;
	*) USERDATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}" ;;
esac

GODOT_PID=""
STUB_PID=""
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

# 이 실행이 만든 user data 디렉터리만 지운다(이름·경로가 예상과 다르면 아무것도 지우지 않음).
remove_userdata() {
	[ "$USERDATA_OWNED" = "1" ] || return 0
	[[ "$USERDIR_NAME" =~ ^overlock_menu_ux_regression_[A-Za-z0-9]+_[0-9]+$ ]] || return 0
	[ "$USERDATA_DIR" = "$USERDATA_ROOT/$USERDIR_NAME" ] || return 0
	[ -d "$USERDATA_DIR" ] && [ ! -L "$USERDATA_DIR" ] || return 0
	chmod -R u+w "$USERDATA_DIR" 2>/dev/null || true
	rm -rf -- "$USERDATA_DIR"
}

cleanup() {
	stop_pid "$GODOT_PID"
	GODOT_PID=""
	stop_pid "$STUB_PID"
	STUB_PID=""
	remove_userdata
	if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
		rm -rf -- "$WORK"
	fi
}

mkdir -p "$TMP_BASE"
WORK="$(mktemp -d "$TMP_BASE/menu_ux_regression.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PROJ="$WORK/game"
USERDIR_NAME="overlock_menu_ux_regression_${WORK##*.}_$$"
USERDATA_DIR="$USERDATA_ROOT/$USERDIR_NAME"
if [ -e "$USERDATA_DIR" ] || [ -L "$USERDATA_DIR" ]; then
	echo "user data 디렉터리가 이미 있습니다(건드리지 않음): $USERDATA_DIR" >&2
	exit 2
fi
USERDATA_OWNED=1

# 1) game/ 사본(.godot 캐시 제외) + 격리 user dir 설정 + 검사 스크립트 복사.
mkdir -p "$PROJ"
(cd "$GAME_SRC" && tar --exclude='./.godot' -cf - .) | (cd "$PROJ" && tar -xf -)
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
mkdir -p "$PROJ/menu_ux_regression"
for f in check.gd check_base.gd check_layout.gd check_prefs.gd check.tscn capture.gd capture.tscn; do
	tr -d '\r' <"$HERE/$f" >"$PROJ/menu_ux_regression/$f"
done

# 2) 지연 리더보드 스텁(127.0.0.1 빈 포트).
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 "$HERE/stub_server.py" "$PORT" >"$WORK/stub.log" 2>&1 &
STUB_PID=$!
STUB="http://127.0.0.1:$PORT"
i=0
until curl -fsS "$STUB/api/health" >/dev/null 2>&1; do
	i=$((i + 1))
	if [ "$i" -gt 100 ]; then
		echo "스텁 서버가 뜨지 않았습니다: $STUB" >&2
		cat "$WORK/stub.log" >&2
		exit 2
	fi
	sleep 0.1
done

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

if [ -n "${DUMP:-}" ]; then
	run_godot "$CHECK_LIMIT" "$WORK/dump.log" --headless --path "$PROJ" \
		res://menu_ux_regression/check.tscn -- "--stub=$STUB" "--dump-layout=$DUMP"
	cat "$WORK/dump.log"
	exit "$RUN_CODE"
fi

# check <이름> <추가 인자...>: 검사 한 번 실행 후 요약 줄 확인. 결과 코드는 CHECK_CODE 에 누적.
CHECK_CODE=0
check() {
	local label="$1"
	shift
	run_godot "$CHECK_LIMIT" "$WORK/check_$label.log" --headless --path "$PROJ" \
		res://menu_ux_regression/check.tscn -- "--stub=$STUB" "--baseline=$HERE/desktop_baseline.json" "$@"
	cat "$WORK/check_$label.log"
	local code=$RUN_CODE
	if [ "$code" -eq 0 ] && ! grep -Eq "^menu ux regression \($label\): [0-9]+ passed, 0 failed$" \
		"$WORK/check_$label.log"; then
		echo "'menu ux regression ($label): N passed, 0 failed' 요약 줄이 출력되지 않았습니다" >&2
		code=3
	fi
	echo "menu ux check ($label) exit=$code"
	[ "$code" -eq 0 ] || CHECK_CODE=$code
}

if [ "$ONLY" = "touch" ]; then
	check touch --touch-controls
elif [ -n "$ONLY" ]; then
	check desktop "--only=$ONLY"
else
	check desktop
	check touch --touch-controls
fi

# 3) 선택: 비-headless 캡처(창 크기 모사, 실기 아님).
if [ -n "${CAPTURE_OUT:-}" ]; then
	mkdir -p "$CAPTURE_OUT"
	for spec in "844x390:touch:--touch-controls" "932x430:touch:--touch-controls" "1280x720:desktop:"; do
		res="${spec%%:*}"
		rest="${spec#*:}"
		mode="${rest%%:*}"
		flag="${rest#*:}"
		run_godot "$CHECK_LIMIT" "$WORK/capture_$res.log" --path "$PROJ" --resolution "$res" \
			res://menu_ux_regression/capture.tscn -- "--stub=$STUB" "--out=$CAPTURE_OUT" \
			"--prefix=${res}_$mode" $flag
		grep -E "^(PX|CAPTURE)" "$WORK/capture_$res.log" || true
		echo "capture $res $mode exit=$RUN_CODE"
	done
fi
exit "$CHECK_CODE"
