#!/usr/bin/env bash
# 아이템 슬롯(FIFO 2칸)·use_item 입력·터치 USE 버튼·자동 일시정지(세로 전환·포커스 상실) 회귀 검사
# 실행기. 같은 check.tscn 을 키보드 모드, 터치 모드(--touch-controls), --no-focus-pause 모드로 세 번
# 실행한다. 데스크톱 헤드리스 모사이며 실제 기기·웹 검증이 아니다.
# 저장소의 game/ 을 임시 디렉터리에 복사한 사본에서만 실행하므로 저장소와 실제 사용자 기록
# (~/Library/Application Support/Godot/app_userdata/Overlock/)을 건드리지 않는다.
# 사본은 실행마다 고유한 custom user dir(overlock_item_slot_regression_<접미사>_<PID>)을 쓰고,
# 종료 시 이 실행이 만든 디렉터리만 지운다.
# 환경변수: GODOT(엔진 경로), ITEM_SLOT_TMP(임시 작업 디렉터리 상위 경로),
#   ITEM_SLOT_TIMEOUT(검사 제한 초, 기본 180), IMPORT_TIMEOUT(headless import 제한 초, 기본 300).
# 모드마다 종료 코드가 0이어도 "item slot regression (<모드>): N passed, 0 failed" 요약 줄이 없으면
# 실패(3)로 본다.
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TMP_BASE="${ITEM_SLOT_TMP:-${TMPDIR:-/tmp}}"
CHECK_LIMIT="${ITEM_SLOT_TIMEOUT:-180}"
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
if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
	echo "HOME 이 비어 있거나 / 입니다" >&2
	exit 2
fi
case "$(uname -s)" in
	Darwin) USERDATA_ROOT="$HOME/Library/Application Support" ;;
	*) USERDATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}" ;;
esac

GODOT_PID=""
USERDIR_NAME=""
USERDATA_DIR=""
USERDATA_OWNED=0

stop_godot() {
	local pid="$GODOT_PID"
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
	GODOT_PID=""
}

# 이 실행이 만든 user data 디렉터리만 지운다(이름·경로가 예상과 다르면 아무것도 지우지 않음).
remove_userdata() {
	[ "$USERDATA_OWNED" = "1" ] || return 0
	[[ "$USERDIR_NAME" =~ ^overlock_item_slot_regression_[A-Za-z0-9]+_[0-9]+$ ]] || return 0
	[ "$USERDATA_DIR" = "$USERDATA_ROOT/$USERDIR_NAME" ] || return 0
	[ -d "$USERDATA_DIR" ] && [ ! -L "$USERDATA_DIR" ] || return 0
	rm -rf -- "$USERDATA_DIR"
}

cleanup() {
	stop_godot
	remove_userdata
	if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
		rm -rf -- "$WORK"
	fi
}

mkdir -p "$TMP_BASE"
WORK="$(mktemp -d "$TMP_BASE/item_slot_regression.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PROJ="$WORK/game"
USERDIR_NAME="overlock_item_slot_regression_${WORK##*.}_$$"
USERDATA_DIR="$USERDATA_ROOT/$USERDIR_NAME"
if [ -e "$USERDATA_DIR" ] || [ -L "$USERDATA_DIR" ]; then
	echo "user data 디렉터리가 이미 있습니다(건드리지 않음): $USERDATA_DIR" >&2
	exit 2
fi
USERDATA_OWNED=1

# 1) game/ 사본(.godot 캐시 제외) + 격리 user dir 설정.
mkdir -p "$PROJ"
(cd "$REPO/game" && tar --exclude='./.godot' -cf - .) | (cd "$PROJ" && tar -xf -)
awk -v userdir="$USERDIR_NAME" '
	{
		line = $0
		cr = ""
		if (sub(/\r$/, "", line)) cr = "\r"
		print
	}
	line == "[application]" && !done {
		print "config/use_custom_user_dir=true" cr
		print "config/custom_user_dir_name=\"" userdir "\"" cr
		done = 1
	}
	END { if (!done) exit 1 }
' "$PROJ/project.godot" >"$PROJ/project.godot.new" || {
	echo "project.godot 에 [application] 섹션이 없습니다" >&2
	exit 2
}
mv "$PROJ/project.godot.new" "$PROJ/project.godot"
mkdir -p "$PROJ/item_slot_regression"
cp "$HERE/check.gd" "$HERE/check_audio.gd" "$HERE/check.tscn" "$PROJ/item_slot_regression/"

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
			stop_godot
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
overall=0
for mode in keys touch nofocus; do
	case "$mode" in
		keys) extra=() ;;
		touch) extra=(-- --touch-controls) ;;
		nofocus) extra=(-- --no-focus-pause) ;;
	esac
	log="$WORK/check_$mode.log"
	run_godot "$CHECK_LIMIT" "$log" --headless --path "$PROJ" res://item_slot_regression/check.tscn \
		${extra[@]+"${extra[@]}"}
	cat "$log"
	code=$RUN_CODE
	if [ "$code" -eq 0 ] && ! grep -Eq "^item slot regression \($mode\): [0-9]+ passed, 0 failed$" "$log"; then
		echo "'item slot regression ($mode): N passed, 0 failed' 요약 줄이 출력되지 않았습니다" >&2
		code=3
	fi
	echo "item slot check ($mode) exit=$code"
	if [ "$code" -ne 0 ]; then
		overall=$code
	fi
done
exit "$overall"
