#!/usr/bin/env bash
# 트랙 밴드(TrackRenderer) 렌더 회귀 검사 실행기. 실제 렌더 결과를 읽으므로 화면이 있어야 한다(비-headless).
# 저장소의 game/ 을 임시 디렉터리에 복사한 사본에서만 실행하므로 저장소와 실제 사용자 기록
# (~/Library/Application Support/Godot/app_userdata/Overlock/)을 건드리지 않는다.
# 사본의 user data 디렉터리는 실행마다 고유한 이름(overlock_track_band_regression_<접미사>_<PID>)을 쓰고,
# 종료 시 이 실행이 만든 디렉터리만 지운다.
# 서버 fixture 트랙(최소 반경 경계·급커브·근접 헤어핀·S커브·스타디움)을 사본에 복사해 함께 검사한다.
# 환경변수: GODOT(엔진 경로), TRACK_BAND_TMP(임시 작업 디렉터리 상위 경로), TRACK_BAND_TIMEOUT(검사 제한 초,
#   기본 600), IMPORT_TIMEOUT(headless import 제한 초, 기본 300), GAME_DIR(검사할 game 디렉터리, 기본 저장소 game/),
#   TRACK_BAND_OUT(디렉터리: 트랙별 렌더 PNG 저장), TRACK_BAND_LEGACY=1(측정만 하고 단언하지 않음. 이전 렌더러 비교용).
# 종료 코드가 0이어도 "track band regression: N passed, 0 failed" 요약 줄이 없으면 실패(3)로 본다.
# 화면이 없는 환경(Linux에서 DISPLAY/WAYLAND_DISPLAY 없음, 또는 TRACK_BAND_NO_DISPLAY=1)이면 SKIPPED를 출력하고
# 통과로 세지 않도록 종료 코드 5로 끝낸다.
set -euo pipefail

GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GAME_DIR="${GAME_DIR:-$REPO/game}"
TMP_BASE="${TRACK_BAND_TMP:-${TMPDIR:-/tmp}}"
CHECK_TIMEOUT="${TRACK_BAND_TIMEOUT:-600}"
IMPORT_LIMIT="${IMPORT_TIMEOUT:-300}"
FIXTURE_SRC="$REPO/server/tests/fixtures/community_tracks"
FIXTURES=(accept_boundary_radius_offset accept_sparse_s_curve accept_stadium_expert reject_hairpin_proximity reject_sharp_corner)
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
has_display=1
if [ "${TRACK_BAND_NO_DISPLAY:-0}" = "1" ]; then
	has_display=0
elif [ "$(uname -s)" != "Darwin" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	has_display=0
fi
if [ "$has_display" = "0" ]; then
	echo "track band regression: SKIPPED (화면 없음, 통과로 세지 않음)"
	exit 5
fi
case "$(uname -s)" in
	Darwin) USERDATA_ROOT="$HOME/Library/Application Support" ;;
	*) USERDATA_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}" ;;
esac
USERDIR_NAME=""
USERDATA_DIR=""
USERDATA_OWNED=0

remove_userdata() {
	[ "$USERDATA_OWNED" = "1" ] || return 0
	[ -n "$USERDIR_NAME" ] && [ -n "$USERDATA_DIR" ] || return 0
	[[ "$USERDIR_NAME" =~ ^overlock_track_band_regression_[A-Za-z0-9]+_[0-9]+$ ]] || return 0
	[ "$USERDATA_DIR" = "$USERDATA_ROOT/$USERDIR_NAME" ] || return 0
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
		kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
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
WORK="$(mktemp -d "$TMP_BASE/track_band_regression.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PROJ="$WORK/game"
USERDIR_NAME="overlock_track_band_regression_${WORK##*.}_$$"
USERDATA_DIR="$USERDATA_ROOT/$USERDIR_NAME"
if [ -e "$USERDATA_DIR" ] || [ -L "$USERDATA_DIR" ]; then
	echo "user data 디렉터리가 이미 있습니다(건드리지 않음): $USERDATA_DIR" >&2
	exit 2
fi
USERDATA_OWNED=1

# 1) game/ 사본(.godot 캐시 제외) + 격리 user dir 설정(CRLF 유지).
mkdir -p "$PROJ"
(cd "$GAME_DIR" && tar --exclude='./.godot' -cf - .) | (cd "$PROJ" && tar -xf -)
awk -v userdir="$USERDIR_NAME" '
	{ line = $0; cr = ""; if (sub(/\r$/, "", line)) cr = "\r"; print }
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

# 2) 검사 스크립트·fixture 복사.
mkdir -p "$PROJ/track_band_regression/fixtures"
cp "$HERE/check.gd" "$HERE/check.tscn" "$PROJ/track_band_regression/"
for f in "${FIXTURES[@]}"; do
	if [ ! -f "$FIXTURE_SRC/$f.json" ]; then
		echo "fixture 를 찾을 수 없습니다: $FIXTURE_SRC/$f.json" >&2
		exit 2
	fi
	cp "$FIXTURE_SRC/$f.json" "$PROJ/track_band_regression/fixtures/"
done

RUN_CODE=0
run_godot() {
	local limit="$1" log="$2"
	shift 2
	"$GODOT" "$@" >"$log" 2>&1 &
	GODOT_PID=$!
	local start=$SECONDS
	while kill -0 "$GODOT_PID" 2>/dev/null; do
		if [ $((SECONDS - start)) -ge "$limit" ]; then
			local pid="$GODOT_PID"
			stop_godot
			echo "시간 초과: ${limit}초 안에 끝나지 않아 Godot(PID $pid)를 종료했습니다" >&2
			RUN_CODE=124
			return 0
		fi
		sleep 1
	done
	RUN_CODE=0
	wait "$GODOT_PID" || RUN_CODE=$?
	GODOT_PID=""
}

# 3) headless import 후 비-headless 검사.
run_godot "$IMPORT_LIMIT" "$WORK/import.log" --headless --path "$PROJ" --import
if [ "$RUN_CODE" -ne 0 ]; then
	echo "import 실패(exit=$RUN_CODE):" >&2
	cat "$WORK/import.log" >&2
	exit 2
fi
ARGS=("--fixtures=$PROJ/track_band_regression/fixtures")
if [ -n "${TRACK_BAND_OUT:-}" ]; then
	mkdir -p "$TRACK_BAND_OUT"
	ARGS+=("--out=$(cd "$TRACK_BAND_OUT" && pwd)")
fi
if [ "${TRACK_BAND_LEGACY:-0}" = "1" ]; then
	ARGS+=("--legacy-ok")
fi
run_godot "$CHECK_TIMEOUT" "$WORK/check.log" --path "$PROJ" --resolution 320x180 --position 40,40 \
	res://track_band_regression/check.tscn -- "${ARGS[@]}"
code=$RUN_CODE
cat "$WORK/check.log"
if [ "$code" -eq 0 ] && ! grep -Eq "^track band regression: [0-9]+ passed, 0 failed$" "$WORK/check.log"; then
	echo "'track band regression: N passed, 0 failed' 요약 줄이 출력되지 않았습니다" >&2
	code=3
fi
if [ "$code" -eq 0 ] && grep -E "SCRIPT ERROR|SHADER ERROR" "$WORK/check.log" >/dev/null; then
	echo "검사 로그에 스크립트/셰이더 오류가 있습니다" >&2
	code=4
fi
echo "track band check exit=$code"
exit "$code"
