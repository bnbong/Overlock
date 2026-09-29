#!/usr/bin/env bash
# 손 밀착 자세·바늘 연출 + 원단 이탈 페널티 알림(토스트) 회귀 검사 실행기.
# 저장소의 game/ 을 임시 디렉터리에 복사한 사본에서만 실행하므로 저장소와 실제 사용자 기록
# (~/Library/Application Support/Godot/app_userdata/Overlock/)을 건드리지 않는다.
# 사본의 user data 디렉터리는 실행마다 고유한 이름(overlock_palm_regression_<접미사>_<PID>)을 써
# 연속·동시 실행이 저장 상태를 공유하지 않게 하고, 종료 시 이 실행이 만든 디렉터리만 지운다.
# (예전 고정 이름 overlock_palm_regression 디렉터리는 자동으로 지우지 않는다.)
# 환경변수: GODOT(엔진 경로), PALM_REGRESSION_TMP(임시 작업 디렉터리 상위 경로),
#   PALM_REGRESSION_TIMEOUT(손·바늘 검사 제한 초, 기본 300), TOAST_REGRESSION_TIMEOUT(토스트 검사
#   제한 초, 기본 180), IMPORT_TIMEOUT(headless import 제한 초, 기본 300).
# 검사 스크립트가 파싱 오류 등으로 quit()에 닿지 못하면 headless Godot 가 끝나지 않으므로, 이 스크립트가
# 띄운 Godot PID 만 제한 시간 뒤 종료시키고 실패(124)로 처리한다(외부 timeout 명령 불필요).
# 종료 코드가 0이어도 검사 요약 줄("... regression: N passed, 0 failed")이 없으면 실패(3)로 본다.
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TMP_BASE="${PALM_REGRESSION_TMP:-${TMPDIR:-/tmp}}"
PALM_TIMEOUT="${PALM_REGRESSION_TIMEOUT:-300}"
TOAST_TIMEOUT="${TOAST_REGRESSION_TIMEOUT:-180}"
IMPORT_LIMIT="${IMPORT_TIMEOUT:-300}"
for v in "$PALM_TIMEOUT" "$TOAST_TIMEOUT" "$IMPORT_LIMIT"; do
	if ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
		echo "제한 시간은 1 이상의 정수(초)여야 합니다: '$v'" >&2
		exit 2
	fi
done

if [ ! -x "$GODOT" ]; then
	echo "Godot 실행 파일을 찾을 수 없습니다: $GODOT (환경변수 GODOT 로 지정)" >&2
	exit 2
fi

# Godot 의 custom user dir 위치(use_custom_user_dir=true): macOS 는 ~/Library/Application Support/<이름>,
# 그 밖(Linux)은 $XDG_DATA_HOME(기본 ~/.local/share)/<이름>.
if [ -z "${HOME:-}" ] || [ "$HOME" = "/" ]; then
	echo "HOME 이 비어 있거나 / 입니다" >&2
	exit 2
fi
case "$(uname -s)" in
	Darwin) USERDATA_ROOT="$HOME/Library/Application Support" ;;
	*) USERDATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}" ;;
esac
USERDIR_PREFIX="overlock_palm_regression_"
USERDIR_NAME=""
USERDATA_DIR=""
# 이 실행이 user data 디렉터리 이름을 새로 확보했을 때만 1(이미 있던 디렉터리는 지우지 않는다).
USERDATA_OWNED=0

# 이 실행이 만든 user data 디렉터리만 지운다. 이름·경로가 조금이라도 예상과 다르면 아무것도
# 지우지 않는다(빈 이름, 접두사 불일치, 경로 구분자·.., 심볼릭 링크, 상위 경로 방지).
remove_userdata() {
	[ "$USERDATA_OWNED" = "1" ] || return 0
	[ -n "$USERDIR_NAME" ] && [ -n "$USERDATA_ROOT" ] && [ -n "$USERDATA_DIR" ] || return 0
	[[ "$USERDIR_NAME" =~ ^overlock_palm_regression_[A-Za-z0-9]+_[0-9]+$ ]] || return 0
	[ "$USERDATA_DIR" = "$USERDATA_ROOT/$USERDIR_NAME" ] || return 0
	[ "$(basename -- "$USERDATA_DIR")" = "$USERDIR_NAME" ] || return 0
	[ "$(dirname -- "$USERDATA_DIR")" = "$USERDATA_ROOT" ] || return 0
	[ -d "$USERDATA_DIR" ] && [ ! -L "$USERDATA_DIR" ] || return 0
	rm -rf -- "$USERDATA_DIR"
}

# 지금 실행 중인(이 스크립트가 띄운) Godot PID. 없으면 빈 값.
GODOT_PID=""

# 이 스크립트가 띄운 Godot 프로세스만 종료시킨다(이름 기반 종료는 하지 않는다).
# TERM 뒤 최대 5초 기다리고, 그래도 남아 있으면 KILL.
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
		if kill -0 "$pid" 2>/dev/null; then
			kill -KILL "$pid" 2>/dev/null || true
		fi
	fi
	wait "$pid" 2>/dev/null || true
	GODOT_PID=""
}

cleanup() {
	stop_godot
	remove_userdata
	if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
		rm -rf -- "$WORK"
	fi
}

mkdir -p "$TMP_BASE"
WORK="$(mktemp -d "$TMP_BASE/palm_regression.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PROJ="$WORK/game"

# 실행마다 고유한 user dir 이름: mktemp 접미사 + PID.
USERDIR_NAME="${USERDIR_PREFIX}${WORK##*.}_$$"
USERDATA_DIR="$USERDATA_ROOT/$USERDIR_NAME"
if [ -e "$USERDATA_DIR" ] || [ -L "$USERDATA_DIR" ]; then
	echo "user data 디렉터리가 이미 있습니다(건드리지 않음): $USERDATA_DIR" >&2
	exit 2
fi
USERDATA_OWNED=1

# 1) game/ 사본 (.godot 캐시는 사본에서 새로 만든다).
mkdir -p "$PROJ"
(cd "$REPO/game" && tar --exclude='./.godot' -cf - .) | (cd "$PROJ" && tar -xf -)

# 2) 사본 project.godot 의 [application] 에 격리 user dir 설정을 추가한다.
# (project.godot 가 CRLF 여도 줄 끝을 그대로 맞춰 쓴다.)
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
' "$PROJ/project.godot" > "$PROJ/project.godot.new" || {
	echo "project.godot 에 [application] 섹션이 없습니다" >&2
	exit 2
}
mv "$PROJ/project.godot.new" "$PROJ/project.godot"

# 3) 검사 스크립트 복사(손·바늘 검사 check + 페널티 알림 토스트 검사 toast_check).
mkdir -p "$PROJ/palm_regression"
cp "$HERE/check.gd" "$HERE/check.tscn" "$HERE/toast_check.gd" "$HERE/toast_check.tscn" \
	"$HERE/toast_spy.gd" "$PROJ/palm_regression/"

# log 파일에서 아직 출력하지 않은 부분만 표준 출력으로 내보낸다(SHOWN: 이미 출력한 바이트 수).
SHOWN=0
flush_log() {
	local log="$1" size
	size="$(wc -c <"$log" | tr -d ' ')"
	if [ "$size" -gt "$SHOWN" ]; then
		tail -c +"$((SHOWN + 1))" "$log" | head -c "$((size - SHOWN))"
		SHOWN="$size"
	fi
}

# 제한 시간 안에서 Godot 를 실행한다: run_godot <제한 초> <log 파일> <표시 여부 1|0> <Godot 인자...>
# 출력은 log 파일에 모으고, 표시 여부가 1이면 진행 중에도 이어서 보여 준다.
# 종료 코드는 RUN_CODE 에 담는다(시간 초과면 124).
RUN_CODE=0
run_godot() {
	local limit="$1" log="$2" show="$3"
	shift 3
	: >"$log"
	SHOWN=0
	"$GODOT" "$@" >"$log" 2>&1 &
	GODOT_PID=$!
	local start=$SECONDS timed_out=0
	while kill -0 "$GODOT_PID" 2>/dev/null; do
		[ "$show" = "1" ] && flush_log "$log"
		if [ $((SECONDS - start)) -ge "$limit" ]; then
			timed_out=1
			break
		fi
		sleep 1
	done
	if [ "$timed_out" = "1" ]; then
		local pid="$GODOT_PID"
		stop_godot
		[ "$show" = "1" ] && flush_log "$log"
		echo "시간 초과: ${limit}초 안에 끝나지 않아 Godot(PID $pid)를 종료했습니다: $*" >&2
		RUN_CODE=124
		return 0
	fi
	RUN_CODE=0
	wait "$GODOT_PID" || RUN_CODE=$?
	GODOT_PID=""
	[ "$show" = "1" ] && flush_log "$log"
	return 0
}

# 검사 하나를 실행하고 종료 코드를 확정한다: run_check <제한 초> <log 파일> <요약 접두사> <씬>
# 종료 코드가 0이어도 "<접두사>: N passed, 0 failed" 요약 줄이 없으면 3.
run_check() {
	local limit="$1" log="$2" prefix="$3" scene="$4"
	run_godot "$limit" "$log" 1 --headless --path "$PROJ" "$scene"
	if [ "$RUN_CODE" -eq 0 ] && ! grep -Eq "^${prefix}: [0-9]+ passed, 0 failed$" "$log"; then
		echo "'${prefix}: N passed, 0 failed' 요약 줄이 출력되지 않았습니다: $scene" >&2
		RUN_CODE=3
	fi
}

# 4) headless import 후 두 검사를 모두 실행한다. 하나라도 실패하면 0이 아닌 종료 코드
#    (앞 검사의 종료 코드를 우선, 둘 다 통과면 0).
run_godot "$IMPORT_LIMIT" "$WORK/import.log" 0 --headless --path "$PROJ" --import
if [ "$RUN_CODE" -ne 0 ]; then
	echo "import 실패(exit=$RUN_CODE):" >&2
	cat "$WORK/import.log" >&2
	exit 2
fi
run_check "$PALM_TIMEOUT" "$WORK/check.log" "palm regression" res://palm_regression/check.tscn
code=$RUN_CODE
run_check "$TOAST_TIMEOUT" "$WORK/toast.log" "toast regression" \
	res://palm_regression/toast_check.tscn
toast_code=$RUN_CODE
echo "palm check exit=$code, toast check exit=$toast_code"
if [ "$code" -ne 0 ]; then
	exit "$code"
fi
exit "$toast_code"
