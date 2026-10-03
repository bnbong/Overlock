#!/usr/bin/env bash
# 드리프트 원단 주름(표현) 회귀 검사 실행기.
# 저장소의 game/ 을 임시 디렉터리에 복사한 사본에서만 실행하므로 저장소와 실제 사용자 기록
# (~/Library/Application Support/Godot/app_userdata/Overlock/)을 건드리지 않는다.
# 사본의 user data 디렉터리는 실행마다 고유한 이름(overlock_folds_regression_<접미사>_<PID>)을 쓰고,
# 종료 시 이 실행이 만든 디렉터리만 지운다.
# 환경변수: GODOT(엔진 경로), FOLDS_REGRESSION_TMP(임시 작업 디렉터리 상위 경로),
#   FOLDS_REGRESSION_TIMEOUT(검사 제한 초, 기본 600), IMPORT_TIMEOUT(headless import 제한 초, 기본 300).
# 검사가 quit()에 닿지 못하면 이 스크립트가 띄운 Godot PID 만 제한 시간 뒤 종료시키고 실패(124)로 처리한다.
# 종료 코드가 0이어도 요약 줄("drift folds regression: N passed, 0 failed")이 없으면 실패(3)로 본다.
# import 로그에 셰이더·스크립트 오류가 있으면 실패(4)로 본다.
# 헤드리스 검사 뒤 비-headless 렌더 단계(capture/run_capture.sh flatcheck)로 셰이더 컴파일과 높이 0 픽셀
# 일치를 확인한다. 화면이 없으면 SKIPPED를 출력하고 종료 코드 5(통과 아님)로 끝낸다.
# FOLDS_FLATCHECK_EXTRA로 캡처 드라이버 인자를 더할 수 있다(예: --flat-max-diff=-1 로 실패 전달 시험).
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TMP_BASE="${FOLDS_REGRESSION_TMP:-${TMPDIR:-/tmp}}"
CHECK_TIMEOUT="${FOLDS_REGRESSION_TIMEOUT:-600}"
IMPORT_LIMIT="${IMPORT_TIMEOUT:-300}"
for v in "$CHECK_TIMEOUT" "$IMPORT_LIMIT"; do
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
USERDIR_PREFIX="overlock_folds_regression_"
USERDIR_NAME=""
USERDATA_DIR=""
USERDATA_OWNED=0

remove_userdata() {
	[ "$USERDATA_OWNED" = "1" ] || return 0
	[ -n "$USERDIR_NAME" ] && [ -n "$USERDATA_ROOT" ] && [ -n "$USERDATA_DIR" ] || return 0
	[[ "$USERDIR_NAME" =~ ^overlock_folds_regression_[A-Za-z0-9]+_[0-9]+$ ]] || return 0
	[ "$USERDATA_DIR" = "$USERDATA_ROOT/$USERDIR_NAME" ] || return 0
	[ "$(basename -- "$USERDATA_DIR")" = "$USERDIR_NAME" ] || return 0
	[ "$(dirname -- "$USERDATA_DIR")" = "$USERDATA_ROOT" ] || return 0
	[ -d "$USERDATA_DIR" ] && [ ! -L "$USERDATA_DIR" ] || return 0
	rm -rf -- "$USERDATA_DIR"
}

GODOT_PID=""
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
WORK="$(mktemp -d "$TMP_BASE/folds_regression.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PROJ="$WORK/game"

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

# 2) 사본 project.godot 의 [application] 에 격리 user dir 설정을 추가한다(CRLF 유지).
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

# 3) 검사 스크립트 복사.
mkdir -p "$PROJ/drift_folds_regression"
cp "$HERE/check.gd" "$HERE/check_base.gd" "$HERE/check_game.gd" "$HERE/check.tscn" \
	"$PROJ/drift_folds_regression/"

SHOWN=0
flush_log() {
	local log="$1" size
	size="$(wc -c <"$log" | tr -d ' ')"
	if [ "$size" -gt "$SHOWN" ]; then
		tail -c +"$((SHOWN + 1))" "$log" | head -c "$((size - SHOWN))"
		SHOWN="$size"
	fi
}

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

# 4) headless import 후 검사 실행.
run_godot "$IMPORT_LIMIT" "$WORK/import.log" 0 --headless --path "$PROJ" --import
if [ "$RUN_CODE" -ne 0 ]; then
	echo "import 실패(exit=$RUN_CODE):" >&2
	cat "$WORK/import.log" >&2
	exit 2
fi
# 셰이더·주름 스크립트 컴파일 오류는 import 로그에 나온다(첫 import의 글꼴 캐시 경고는 제외).
if grep -E "SHADER ERROR|Parse Error|drift_fold|DriftFold|DriftSkid" "$WORK/import.log" \
	| grep -Ei "error" >/dev/null; then
	echo "import 로그에 주름 셰이더/스크립트 오류가 있습니다:" >&2
	grep -E "SHADER ERROR|Parse Error|drift_fold|DriftFold|DriftSkid" "$WORK/import.log" >&2
	exit 4
fi
run_godot "$CHECK_TIMEOUT" "$WORK/check.log" 1 --headless --path "$PROJ" \
	res://drift_folds_regression/check.tscn
code=$RUN_CODE
if [ "$code" -eq 0 ] && ! grep -Eq "^drift folds regression: [0-9]+ passed, 0 failed$" "$WORK/check.log"; then
	echo "'drift folds regression: N passed, 0 failed' 요약 줄이 출력되지 않았습니다" >&2
	code=3
fi
if [ "$code" -eq 0 ] && grep -E "SCRIPT ERROR|SHADER ERROR" "$WORK/check.log" >/dev/null; then
	echo "검사 로그에 스크립트/셰이더 오류가 있습니다" >&2
	code=4
fi
# 런타임에 쓰면 안 되는 에디터 전용 API 경고(global_shader_parameter_get_list 등)가 0건이어야 한다.
EDITOR_ONLY_RE="should never be used outside the editor"
editor_only="$(grep -c "$EDITOR_ONLY_RE" "$WORK/check.log" || true)"
echo "editor-only API errors (headless): $editor_only"
if [ "$editor_only" != "0" ]; then
	echo "헤드리스 검사 로그에 에디터 전용 API 오류가 있습니다" >&2
	grep "$EDITOR_ONLY_RE" "$WORK/check.log" | head -3 >&2
	[ "$code" -ne 0 ] || code=4
fi
if [ -n "${FOLDS_REGRESSION_LOG:-}" ]; then
	cp "$WORK/check.log" "$FOLDS_REGRESSION_LOG"
fi
echo "drift folds check exit=$code"

# 5) 비-headless 렌더 단계: 실제 셰이더 컴파일과 높이 0 픽셀 일치(flatcheck)를 종료 코드로 확인한다.
#    화면이 없는 환경(Linux에서 DISPLAY/WAYLAND_DISPLAY 없음, 또는 FOLDS_NO_DISPLAY=1)이면 SKIPPED로
#    표시하고, 통과로 세지 않도록 종료 코드 5를 쓴다(헤드리스 단계가 실패했으면 그 코드를 우선).
render_code=0
has_display=1
if [ "${FOLDS_NO_DISPLAY:-0}" = "1" ]; then
	has_display=0
elif [ "$(uname -s)" != "Darwin" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	has_display=0
fi
if [ "$has_display" = "1" ]; then
	RENDER_OUT="$WORK/render_flatcheck"
	FOLD_CAPTURE_TMP="$WORK" GODOT="$GODOT" \
		bash "$HERE/capture/run_capture.sh" flatcheck "$RENDER_OUT" 1280x720 tee_01 \
		"${FOLDS_FLATCHECK_EXTRA:-}" || render_code=$?
	grep -h "flatcheck" "$RENDER_OUT/events.txt" 2>/dev/null || true
	for f in flat_A_h0_opaque flat_B_layer_off flat_C_normal; do
		if [ ! -f "$RENDER_OUT/$f.png" ]; then
			echo "예상 캡처가 없습니다: $f.png" >&2
			[ "$render_code" -ne 0 ] || render_code=3
		fi
	done
	if [ "$render_code" -eq 0 ] && ! grep -q "flatcheck PASS" "$RENDER_OUT/events.txt"; then
		render_code=3
	fi
	render_editor_only="$(grep -c "$EDITOR_ONLY_RE" "$RENDER_OUT/godot.log" 2>/dev/null || true)"
	echo "editor-only API errors (render): ${render_editor_only:-?}"
	if [ "${render_editor_only:-1}" != "0" ]; then
		echo "렌더 단계 로그에 에디터 전용 API 오류가 있습니다" >&2
		[ "$render_code" -ne 0 ] || render_code=4
	fi
	echo "drift folds render check exit=$render_code"
else
	echo "drift folds render check: SKIPPED (화면 없음, 통과로 세지 않음)"
	render_code=5
fi
if [ "$code" -ne 0 ]; then
	exit "$code"
fi
exit "$render_code"
