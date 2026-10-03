#!/usr/bin/env bash
# 드리프트 주름 화면 캡처 실행기(비-headless 렌더 창).
# game/(또는 GAME_DIR) 을 임시 사본으로 복사하고, 사본 project.godot 에만 격리 user dir 과 FoldCapture
# autoload 를 추가해 Gameplay.tscn 을 직접 실행한다. 저장소와 실제 사용자 기록은 건드리지 않는다.
# usage: run_capture.sh <main|fabric|mobile|compare|flatcheck|perf> <출력 디렉터리> [WxH] [track_id] [추가 인자]
# 종료 코드: 0=성공, 1=드라이버가 실패를 기록(화면 비교 실패·캡처 누락), 2=import 실패,
#   3=완료 표식 없음(중간 종료·파싱 오류), 4=스크립트/셰이더 오류 로그, 그 밖=Godot 종료 코드.
# 환경변수: GODOT, GAME_DIR(기본 저장소 game/), FOLD_CAPTURE_TMP(임시 상위 경로)
set -euo pipefail
GODOT="${GODOT:-/Users/bnbong/Downloads/Godot.app/Contents/MacOS/Godot}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
GAME_DIR="${GAME_DIR:-$REPO/game}"
SCEN="${1:?scenario}"
OUT="${2:?out dir}"
RES="${3:-1280x720}"
TRACK="${4:-tee_01}"
EXTRA="${5:-}"
TMP_BASE="${FOLD_CAPTURE_TMP:-${TMPDIR:-/tmp}}"
mkdir -p "$TMP_BASE" "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d "$TMP_BASE/fold_capture.XXXXXX")"
UD_NAME="overlock_fold_capture_${WORK##*.}_$$"
UDIR="$HOME/Library/Application Support/$UD_NAME"
cleanup() {
	rm -rf -- "$WORK"
	case "$UD_NAME" in overlock_fold_capture_*) [ -d "$UDIR" ] && rm -rf -- "$UDIR" ;; esac
}
trap cleanup EXIT
PROJ="$WORK/game"
mkdir -p "$PROJ"
(cd "$GAME_DIR" && tar --exclude='./.godot' -cf - .) | (cd "$PROJ" && tar -xf -)
mkdir -p "$PROJ/fold_capture"
cp "$HERE/FoldCapture.gd" "$PROJ/fold_capture/"
awk -v ud="$UD_NAME" '
	{ line = $0; cr = ""; if (sub(/\r$/, "", line)) cr = "\r"; print }
	line == "[application]" && !app {
		print "config/use_custom_user_dir=true" cr
		print "config/custom_user_dir_name=\"" ud "\"" cr
		app = 1
	}
	line ~ /^OrientationGuard=/ && !ad { print "FoldCapture=\"*res://fold_capture/FoldCapture.gd\"" cr; ad = 1 }
	END { if (!app || !ad) exit 1 }
' "$PROJ/project.godot" >"$PROJ/project.godot.new"
mv "$PROJ/project.godot.new" "$PROJ/project.godot"
if ! "$GODOT" --headless --path "$PROJ" --import >"$WORK/import.log" 2>&1; then
	echo "import 실패" >&2
	tail -20 "$WORK/import.log" >&2
	exit 2
fi
code=0
"$GODOT" --path "$PROJ" --fixed-fps 60 --resolution "$RES" --position 40,40 \
	res://scenes/Gameplay.tscn -- --no-focus-pause --out="$OUT" --scenario="$SCEN" --track="$TRACK" $EXTRA \
	>"$OUT/godot.log" 2>&1 || code=$?
grep -E "SCRIPT ERROR|SHADER ERROR|Shader compilation failed" "$OUT/godot.log" | head -20 || true
if grep -Eq "SCRIPT ERROR|SHADER ERROR|Shader compilation failed" "$OUT/godot.log"; then
	echo "캡처 로그에 스크립트/셰이더 오류가 있습니다" >&2
	[ "$code" -ne 0 ] || code=4
fi
if ! grep -Eq "\] done failures=0$" "$OUT/events.txt" 2>/dev/null; then
	echo "캡처 드라이버가 실패 없이 끝나지 않았습니다(events.txt 확인)" >&2
	grep -E "FAIL|done" "$OUT/events.txt" 2>/dev/null | head -10 >&2 || true
	[ "$code" -ne 0 ] || code=3
fi
echo "captures: $(grep -c "capture " "$OUT/events.txt" 2>/dev/null || echo 0), exit=$code"
exit "$code"
